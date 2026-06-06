module Main exposing (main)

import Browser
import Browser.Navigation as Nav
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onClick, onInput, onSubmit)
import Http
import Json.Decode as D
import Json.Encode as E
import Time exposing (Posix)
import Url
import Url.Parser as Parser exposing ((</>), Parser, int, s, string)
import Svg exposing (..)
import Svg.Attributes as SA exposing (..)



-- MAIN


main : Program () Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = \_ -> Sub.none
        , onUrlChange = UrlChanged
        , onUrlRequest = LinkClicked
        }



-- MODEL


type Route
    = ListRoute
    | DetailRoute Int
    | NotFoundRoute


type alias Model =
    { navKey : Nav.Key
    , url : Url.Url
    , route : Route
    , batches : List CocoonBatch
    , selectedBatch : Maybe BatchDetail
    , loading : Bool
    , error : Maybe String
    , newBatchForm : NewBatchForm
    , outboundError : Maybe String
    }


type alias CocoonBatch =
    { id : Int
    , cocoon_type : String
    , target_reeling_kg : Float
    , target_temp : Float
    , status : String
    , is_suspect : Bool
    , created_at : Posix
    }


type alias BoilCurve =
    { id : Int
    , batch_id : Int
    , temp_c : Float
    , recorded_at : Posix
    }


type alias FloatEvent =
    { id : Int
    , batch_id : Int
    , float_ratio_pct : Float
    , recorded_at : Posix
    }


type alias UnderheatSegment =
    { start_time : Posix
    , end_time : Posix
    , min_temp : Float
    }


type alias BatchDetail =
    { batch : CocoonBatch
    , boil_curves : List BoilCurve
    , float_events : List FloatEvent
    , underheat_segments : List UnderheatSegment
    }


type alias NewBatchForm =
    { cocoonType : String
    , targetReelingKg : String
    , targetTemp : String
    }


init : () -> Url.Url -> Nav.Key -> ( Model, Cmd Msg )
init _ url key =
    let
        route =
            parseRoute url
    in
    ( { navKey = key
      , url = url
      , route = route
      , batches = []
      , selectedBatch = Nothing
      , loading = True
      , error = Nothing
      , newBatchForm =
            { cocoonType = ""
            , targetReelingKg = ""
            , targetTemp = ""
            }
      , outboundError = Nothing
      }
    , case route of
        ListRoute ->
            fetchBatches

        DetailRoute id ->
            Cmd.batch [ fetchBatches, fetchBatchDetail id ]

        NotFoundRoute ->
            Cmd.none
    )



-- ROUTING


parseRoute : Url.Url -> Route
parseRoute url =
    Parser.parse routeParser url
        |> Maybe.withDefault ListRoute


routeParser : Parser (Route -> a) a
routeParser =
    Parser.oneOf
        [ Parser.map ListRoute Parser.top
        , Parser.map DetailRoute (s "batch" </> int)
        ]



-- MSG


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url.Url
    | FetchBatchesResult (Result Http.Error (List CocoonBatch))
    | FetchBatchDetailResult (Result Http.Error BatchDetail)
    | UpdateForm NewBatchForm
    | SubmitNewBatch
    | CreateBatchResult (Result Http.Error CocoonBatch)
    | MarkOutbound Int
    | OutboundResult Int (Result Http.Error ())
    | ExportReport Int
    | CloseOutboundError



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.navKey (Url.toString url) )

                Browser.External href ->
                    ( model, Nav.load href )

        UrlChanged url ->
            let
                route =
                    parseRoute url

                newCmd =
                    case route of
                        ListRoute ->
                            fetchBatches

                        DetailRoute id ->
                            fetchBatchDetail id

                        NotFoundRoute ->
                            Cmd.none
            in
            ( { model | url = url, route = route, loading = True, selectedBatch = Nothing, outboundError = Nothing }
            , newCmd
            )

        FetchBatchesResult (Ok batches) ->
            ( { model | batches = batches, loading = False, error = Nothing }, Cmd.none )

        FetchBatchesResult (Err e) ->
            ( { model | loading = False, error = Just (httpErrorToString e) }, Cmd.none )

        FetchBatchDetailResult (Ok detail) ->
            ( { model
                | selectedBatch = Just detail
                , loading = False
                , error = Nothing
                , batches =
                    if List.any (\b -> b.id == detail.batch.id) model.batches then
                        List.map
                            (\b ->
                                if b.id == detail.batch.id then
                                    detail.batch

                                else
                                    b
                            )
                            model.batches

                    else
                        detail.batch :: model.batches
              }
            , Cmd.none
            )

        FetchBatchDetailResult (Err e) ->
            ( { model | loading = False, error = Just (httpErrorToString e) }, Cmd.none )

        UpdateForm form ->
            ( { model | newBatchForm = form }, Cmd.none )

        SubmitNewBatch ->
            ( model, createBatch model.newBatchForm )

        CreateBatchResult (Ok batch) ->
            ( { model
                | batches = batch :: model.batches
                , newBatchForm =
                    { cocoonType = ""
                    , targetReelingKg = ""
                    , targetTemp = ""
                    }
              }
            , Cmd.none
            )

        CreateBatchResult (Err e) ->
            ( { model | error = Just (httpErrorToString e) }, Cmd.none )

        MarkOutbound id ->
            ( model, markOutbound id )

        OutboundResult id (Ok ()) ->
            let
                updatedBatches =
                    List.map
                        (\b ->
                            if b.id == id then
                                { b | status = "outbound" }

                            else
                                b
                        )
                        model.batches

                updatedSelected =
                    Maybe.map
                        (\d -> { d | batch = { d.batch | status = "outbound" } })
                        model.selectedBatch
            in
            ( { model | batches = updatedBatches, selectedBatch = updatedSelected, outboundError = Nothing }
            , Cmd.none
            )

        OutboundResult id (Err e) ->
            case e of
                Http.BadStatus 409 ->
                    ( { model | outboundError = Just "批次存在质量问题（低温+低浮茧），禁止出库" }, Cmd.none )

                _ ->
                    ( { model | error = Just (httpErrorToString e) }, Cmd.none )

        ExportReport id ->
            ( model, exportReport id )

        CloseOutboundError ->
            ( { model | outboundError = Nothing }, Cmd.none )



-- HTTP


apiBase : String
apiBase =
    "/api"


fetchBatches : Cmd Msg
fetchBatches =
    Http.get
        { url = apiBase ++ "/batches"
        , expect = Http.expectJson FetchBatchesResult (D.list batchDecoder)
        }


fetchBatchDetail : Int -> Cmd Msg
fetchBatchDetail id =
    Http.get
        { url = apiBase ++ "/batches/" ++ String.fromInt id
        , expect = Http.expectJson FetchBatchDetailResult batchDetailDecoder
        }


createBatch : NewBatchForm -> Cmd Msg
createBatch form =
    Http.post
        { url = apiBase ++ "/batches"
        , body =
            Http.jsonBody
                (E.object
                    [ ( "cocoon_type", E.string form.cocoonType )
                    , ( "target_reeling_kg"
                      , E.float (Maybe.withDefault 0 (String.toFloat form.targetReelingKg))
                      )
                    , ( "target_temp"
                      , E.float (Maybe.withDefault 0 (String.toFloat form.targetTemp))
                      )
                    ]
                )
        , expect = Http.expectJson CreateBatchResult batchDecoder
        }


markOutbound : Int -> Cmd Msg
markOutbound id =
    Http.request
        { method = "PATCH"
        , headers = []
        , url = apiBase ++ "/batches/" ++ String.fromInt id ++ "/outbound"
        , body = Http.emptyBody
        , expect = Http.expectWhatever (OutboundResult id)
        , timeout = Nothing
        , tracker = Nothing
        }


exportReport : Int -> Cmd msg
exportReport id =
    Nav.load (apiBase ++ "/batches/" ++ String.fromInt id ++ "/report")



-- DECODERS


batchDecoder : D.Decoder CocoonBatch
batchDecoder =
    D.map7 CocoonBatch
        (D.field "id" D.int)
        (D.field "cocoon_type" D.string)
        (D.field "target_reeling_kg" D.float)
        (D.field "target_temp" D.float)
        (D.field "status" D.string)
        (D.field "is_suspect" D.bool)
        (D.field "created_at" posixDecoder)


boilCurveDecoder : D.Decoder BoilCurve
boilCurveDecoder =
    D.map4 BoilCurve
        (D.field "id" D.int)
        (D.field "batch_id" D.int)
        (D.field "temp_c" D.float)
        (D.field "recorded_at" posixDecoder)


floatEventDecoder : D.Decoder FloatEvent
floatEventDecoder =
    D.map4 FloatEvent
        (D.field "id" D.int)
        (D.field "batch_id" D.int)
        (D.field "float_ratio_pct" D.float)
        (D.field "recorded_at" posixDecoder)


underheatSegmentDecoder : D.Decoder UnderheatSegment
underheatSegmentDecoder =
    D.map3 UnderheatSegment
        (D.field "start_time" posixDecoder)
        (D.field "end_time" posixDecoder)
        (D.field "min_temp" D.float)


batchDetailDecoder : D.Decoder BatchDetail
batchDetailDecoder =
    D.map4 BatchDetail
        (D.field "batch" batchDecoder)
        (D.field "boil_curves" (D.list boilCurveDecoder))
        (D.field "float_events" (D.list floatEventDecoder))
        (D.field "underheat_segments" (D.list underheatSegmentDecoder))


posixDecoder : D.Decoder Posix
posixDecoder =
    D.map Time.millisToPosix D.int



-- VIEW


view : Model -> Browser.Document Msg
view model =
    { title = "缫丝厂单机系统"
    , body =
        [ div [ style "padding" "20px", style "max-width" "1400px", style "margin" "0 auto" ]
            [ headerView
            , case model.error of
                Just err ->
                    errorView err

                Nothing ->
                    text ""
            , case model.outboundError of
                Just err ->
                    outboundErrorView err

                Nothing ->
                    text ""
            , if model.loading then
                div [ style "text-align" "center", style "padding" "40px" ]
                    [ text "加载中..." ]

              else
                case model.route of
                    ListRoute ->
                        listView model

                    DetailRoute id ->
                        detailView model id

                    NotFoundRoute ->
                        div [ style "text-align" "center", style "padding" "40px" ]
                            [ text "页面未找到"
                            , a [ href "/", style "display" "block", style "margin-top" "10px" ]
                                [ text "返回首页" ]
                            ]
            ]
        ]
    }


headerView : Html Msg
headerView =
    div
        [ style "background" "linear-gradient(135deg, #667eea 0%, #764ba2 100%)"
        , style "color" "white"
        , style "padding" "20px 30px"
        , style "border-radius" "10px"
        , style "margin-bottom" "20px"
        ]
        [ h1 [ style "margin" "0", style "font-size" "24px" ]
            [ text "煮茧池温度曲线与浮茧批次追溯系统" ]
        , p [ style "margin" "5px 0 0 0", style "opacity" "0.9" ]
            [ text "缫丝厂单机系统 - 单机版" ]
        ]


errorView : String -> Html Msg
errorView msg =
    div
        [ style "background" "#fee2e2"
        , style "border" "1px solid #fecaca"
        , style "color" "#991b1b"
        , style "padding" "12px 16px"
        , style "border-radius" "6px"
        , style "margin-bottom" "16px"
        ]
        [ text ("错误: " ++ msg) ]


outboundErrorView : String -> Html Msg
outboundErrorView msg =
    div
        [ style "background" "#fef3c7"
        , style "border" "1px solid #fcd34d"
        , style "color" "#92400e"
        , style "padding" "16px"
        , style "border-radius" "8px"
        , style "margin-bottom" "16px"
        , style "display" "flex"
        , style "justify-content" "space-between"
        , style "align-items" "center"
        ]
        [ div []
            [ strong [] [ text "出库失败: " ]
            , text msg
            ]
        , button
            [ onClick CloseOutboundError
            , style "background" "none"
            , style "border" "none"
            , style "cursor" "pointer"
            , style "font-size" "18px"
            , style "color" "#92400e"
            ]
            [ text "×" ]
        ]


listView : Model -> Html Msg
listView model =
    div []
        [ createBatchFormView model
        , div
            [ style "background" "white"
            , style "border-radius" "10px"
            , style "box-shadow" "0 2px 8px rgba(0,0,0,0.08)"
            , style "overflow" "hidden"
            ]
            [ div
                [ style "padding" "20px"
                , style "border-bottom" "1px solid #e5e7eb"
                , style "display" "flex"
                , style "justify-content" "space-between"
                , style "align-items" "center"
                ]
                [ h2 [ style "margin" "0", style "font-size" "18px" ]
                    [ text "批次列表" ]
                , span [ style "color" "#6b7280", style "font-size" "14px" ]
                    [ text ("共 " ++ String.fromInt (List.length model.batches) ++ " 个批次") ]
                ]
            , if List.isEmpty model.batches then
                div
                    [ style "padding" "60px 20px"
                    , style "text-align" "center"
                    , style "color" "#9ca3af"
                    ]
                    [ text "暂无批次数据" ]

              else
                table
                    [ style "width" "100%"
                    , style "border-collapse" "collapse"
                    ]
                    [ thead []
                        [ tr
                            [ style "background" "#f9fafb" ]
                            [ th [ tableHeaderStyle ] [ text "批次ID" ]
                            , th [ tableHeaderStyle ] [ text "茧型" ]
                            , th [ tableHeaderStyle ] [ text "目标缫量(kg)" ]
                            , th [ tableHeaderStyle ] [ text "目标温度(°C)" ]
                            , th [ tableHeaderStyle ] [ text "状态" ]
                            , th [ tableHeaderStyle ] [ text "可疑" ]
                            , th [ tableHeaderStyle ] [ text "创建时间" ]
                            , th [ tableHeaderStyle ] [ text "操作" ]
                            ]
                        ]
                    , tbody []
                        (List.map batchRowView model.batches)
                    ]
            ]
        ]


tableHeaderStyle : Attribute msg
tableHeaderStyle =
    styleList
        [ ( "padding", "12px 16px" )
        , ( "text-align", "left" )
        , ( "font-weight", "600" )
        , ( "font-size", "12px" )
        , ( "color", "#374151" )
        , ( "border-bottom", "1px solid #e5e7eb" )
        , ( "text-transform", "uppercase" )
        , ( "letter-spacing", "0.05em" )
        ]


batchRowView : CocoonBatch -> Html Msg
batchRowView batch =
    let
        rowBg =
            if batch.is_suspect then
                style "background" "#fef2f2"

            else
                style "background" "white"
    in
    tr
        [ rowBg
        , style "border-bottom" "1px solid #f3f4f6"
        , style "transition" "background 0.2s"
        ]
        [ td [ tdStyle ] [ text (String.fromInt batch.id) ]
        , td [ tdStyle ] [ text batch.cocoon_type ]
        , td [ tdStyle ] [ text (formatFloat batch.target_reeling_kg) ]
        , td [ tdStyle ] [ text (formatFloat batch.target_temp) ]
        , td [ tdStyle ] [ statusBadge batch.status ]
        , td [ tdStyle ] [ suspectBadge batch.is_suspect ]
        , td [ tdStyle ] [ text (formatTime batch.created_at) ]
        , td [ tdStyle ]
            [ div [ style "display" "flex", style "gap" "8px" ]
                [ a
                    [ href ("/batch/" ++ String.fromInt batch.id)
                    , style "background" "#3b82f6"
                    , style "color" "white"
                    , style "padding" "6px 12px"
                    , style "border-radius" "6px"
                    , style "font-size" "12px"
                    , style "text-decoration" "none"
                    , style "transition" "background 0.2s"
                    ]
                    [ text "详情" ]
                , button
                    [ onClick (MarkOutbound batch.id)
                    , disabled (batch.status == "outbound")
                    , style "background"
                        (if batch.status == "outbound" then
                            "#d1d5db"

                         else
                            "#10b981"
                        )
                    , style "color" "white"
                    , style "padding" "6px 12px"
                    , style "border" "none"
                    , style "border-radius" "6px"
                    , style "font-size" "12px"
                    , style "cursor"
                        (if batch.status == "outbound" then
                            "not-allowed"

                         else
                            "pointer"
                        )
                    , style "transition" "background 0.2s"
                    ]
                    [ text
                        (if batch.status == "outbound" then
                            "已出库"

                         else
                            "出库"
                        )
                    ]
                ]
            ]
        ]


tdStyle : Attribute msg
tdStyle =
    styleList
        [ ( "padding", "12px 16px" )
        , ( "font-size", "14px" )
        , ( "color", "#1f2937" )
        ]


statusBadge : String -> Html msg
statusBadge status =
    let
        ( bg, color ) =
            case status of
                "active" ->
                    ( "#dbeafe", "#1e40af" )

                "outbound" ->
                    ( "#d1fae5", "#065f46" )

                _ ->
                    ( "#f3f4f6", "#374151" )
    in
    span
        [ style "background" bg
        , style "color" color
        , style "padding" "4px 10px"
        , style "border-radius" "9999px"
        , style "font-size" "12px"
        , style "font-weight" "500"
        ]
        [ text
            (case status of
                "active" ->
                    "生产中"

                "outbound" ->
                    "已出库"

                _ ->
                    status
            )
        ]


suspectBadge : Bool -> Html msg
suspectBadge isSuspect =
    if isSuspect then
        span
            [ style "background" "#fee2e2"
            , style "color" "#991b1b"
            , style "padding" "4px 10px"
            , style "border-radius" "9999px"
            , style "font-size" "12px"
            , style "font-weight" "600"
            , style "animation" "pulse 2s infinite"
            ]
            [ text "⚠ 可疑" ]

    else
        span
            [ style "background" "#d1fae5"
            , style "color" "#065f46"
            , style "padding" "4px 10px"
            , style "border-radius" "9999px"
            , style "font-size" "12px"
            , style "font-weight" "500"
            ]
            [ text "正常" ]


createBatchFormView : Model -> Html Msg
createBatchFormView model =
    div
        [ style "background" "white"
        , style "border-radius" "10px"
        , style "box-shadow" "0 2px 8px rgba(0,0,0,0.08)"
        , style "padding" "20px"
        , style "margin-bottom" "20px"
        ]
        [ h3 [ style "margin" "0 0 15px 0", style "font-size" "16px" ]
            [ text "登记新批次" ]
        , Html.form
            [ onSubmit SubmitNewBatch
            , style "display" "grid"
            , style "grid-template-columns" "repeat(auto-fit, minmax(200px, 1fr))"
            , style "gap" "16px"
            , style "align-items" "end"
            ]
            [ div []
                [ label
                    [ style "display" "block"
                    , style "font-size" "12px"
                    , style "font-weight" "500"
                    , style "color" "#374151"
                    , style "margin-bottom" "6px"
                    ]
                    [ text "茧型" ]
                , input
                    [ type_ "text"
                    , placeholder "如：双宫茧"
                    , value model.newBatchForm.cocoonType
                    , onInput (\v -> UpdateForm { model.newBatchForm | cocoonType = v })
                    , inputStyle
                    , required True
                    ]
                    []
                ]
            , div []
                [ label
                    [ style "display" "block"
                    , style "font-size" "12px"
                    , style "font-weight" "500"
                    , style "color" "#374151"
                    , style "margin-bottom" "6px"
                    ]
                    [ text "目标缫量 (kg)" ]
                , input
                    [ type_ "number"
                    , placeholder "如：100"
                    , value model.newBatchForm.targetReelingKg
                    , onInput (\v -> UpdateForm { model.newBatchForm | targetReelingKg = v })
                    , inputStyle
                    , step "0.01"
                    , required True
                    ]
                    []
                ]
            , div []
                [ label
                    [ style "display" "block"
                    , style "font-size" "12px"
                    , style "font-weight" "500"
                    , style "color" "#374151"
                    , style "margin-bottom" "6px"
                    ]
                    [ text "目标温度 (°C)" ]
                , input
                    [ type_ "number"
                    , placeholder "如：98"
                    , value model.newBatchForm.targetTemp
                    , onInput (\v -> UpdateForm { model.newBatchForm | targetTemp = v })
                    , inputStyle
                    , step "0.1"
                    , required True
                    ]
                    []
                ]
            , button
                [ type_ "submit"
                , style "background" "#667eea"
                , style "color" "white"
                , style "border" "none"
                , style "padding" "10px 20px"
                , style "border-radius" "6px"
                , style "font-size" "14px"
                , style "font-weight" "500"
                , style "cursor" "pointer"
                , style "transition" "background 0.2s"
                ]
                [ text "登记批次" ]
            ]
        ]


inputStyle : Attribute msg
inputStyle =
    styleList
        [ ( "width", "100%" )
        , ( "padding", "8px 12px" )
        , ( "border", "1px solid #d1d5db" )
        , ( "border-radius", "6px" )
        , ( "font-size", "14px" )
        , ( "box-sizing", "border-box" )
        , ( "outline", "none" )
        ]


detailView : Model -> Int -> Html Msg
detailView model id =
    case model.selectedBatch of
        Just detail ->
            div []
                [ a
                    [ href "/"
                    , style "display" "inline-block"
                    , style "margin-bottom" "16px"
                    , style "color" "#3b82f6"
                    , style "text-decoration" "none"
                    ]
                    [ text "← 返回列表" ]
                , batchInfoCard detail
                , dualAxisChart detail
                , actionButtons detail
                ]

        Nothing ->
            div [ style "text-align" "center", style "padding" "40px" ]
                [ text "加载批次详情中..." ]


batchInfoCard : BatchDetail -> Html Msg
batchInfoCard detail =
    let
        batch =
            detail.batch
    in
    div
        [ style "background" "white"
        , style "border-radius" "10px"
        , style "box-shadow" "0 2px 8px rgba(0,0,0,0.08)"
        , style "padding" "24px"
        , style "margin-bottom" "20px"
        ]
        [ div
            [ style "display" "flex"
            , style "justify-content" "space-between"
            , style "align-items" "flex-start"
            , style "flex-wrap" "wrap"
            , style "gap" "16px"
            ]
            [ div []
                [ h2 [ style "margin" "0 0 8px 0", style "font-size" "20px" ]
                    [ text ("批次 #" ++ String.fromInt batch.id) ]
                , p [ style "margin" "0", style "color" "#6b7280" ]
                    [ text ("茧型: " ++ batch.cocoon_type)
                    , span [ style "margin" "0 12px" ] [ text "|" ]
                    , text ("创建时间: " ++ formatTime batch.created_at)
                    ]
                ]
            , div [ style "display" "flex", style "gap" "10px" ]
                [ statusBadge batch.status
                , suspectBadge batch.is_suspect
                ]
            ]
        , div
            [ style "display" "grid"
            , style "grid-template-columns" "repeat(auto-fit, minmax(200px, 1fr))"
            , style "gap" "20px"
            , style "margin-top" "20px"
            , style "padding-top" "20px"
            , style "border-top" "1px solid #e5e7eb"
            ]
            [ infoItem "目标缫量" (formatFloat batch.target_reeling_kg ++ " kg")
            , infoItem "目标温度" (formatFloat batch.target_temp ++ " °C")
            , infoItem "低温段数" (String.fromInt (List.length detail.underheat_segments))
            , infoItem "温度记录数" (String.fromInt (List.length detail.boil_curves))
            , infoItem "浮茧记录数" (String.fromInt (List.length detail.float_events))
            ]
        ]


infoItem : String -> String -> Html msg
infoItem label value =
    div []
        [ p
            [ style "margin" "0 0 4px 0"
            , style "font-size" "12px"
            , style "color" "#6b7280"
            , style "text-transform" "uppercase"
            , style "letter-spacing" "0.05em"
            ]
            [ text label ]
        , p
            [ style "margin" "0"
            , style "font-size" "18px"
            , style "font-weight" "600"
            , style "color" "#1f2937"
            ]
            [ text value ]
        ]


actionButtons : BatchDetail -> Html Msg
actionButtons detail =
    div
        [ style "background" "white"
        , style "border-radius" "10px"
        , style "box-shadow" "0 2px 8px rgba(0,0,0,0.08)"
        , style "padding" "20px"
        , style "display" "flex"
        , style "gap" "12px"
        , style "flex-wrap" "wrap"
        ]
        [ button
            [ onClick (MarkOutbound detail.batch.id)
            , disabled (detail.batch.status == "outbound")
            , style "background"
                (if detail.batch.status == "outbound" then
                    "#d1d5db"

                 else if detail.batch.is_suspect then
                    "#f59e0b"

                 else
                    "#10b981"
                )
            , style "color" "white"
            , style "border" "none"
            , style "padding" "10px 20px"
            , style "border-radius" "6px"
            , style "font-size" "14px"
            , style "font-weight" "500"
            , style "cursor"
                (if detail.batch.status == "outbound" then
                    "not-allowed"

                 else
                    "pointer"
                )
            , style "transition" "background 0.2s"
            ]
            [ text
                (if detail.batch.status == "outbound" then
                    "已出库"

                 else
                    "出库"
                )
            ]
        , button
            [ onClick (ExportReport detail.batch.id)
            , style "background" "#667eea"
            , style "color" "white"
            , style "border" "none"
            , style "padding" "10px 20px"
            , style "border-radius" "6px"
            , style "font-size" "14px"
            , style "font-weight" "500"
            , style "cursor" "pointer"
            , style "transition" "background 0.2s"
            ]
            [ text "导出CSV报告" ]
        ]



-- DUAL AXIS CHART


type alias ChartDim =
    { width : Float
    , height : Float
    , margin : { top : Float, right : Float, bottom : Float, left : Float }
    }


dualAxisChart : BatchDetail -> Html Msg
dualAxisChart detail =
    let
        dim =
            { width = 1000
            , height = 450
            , margin = { top = 40, right = 60, bottom = 60, left = 60 }
            }

        innerWidth =
            dim.width - dim.margin.left - dim.margin.right

        innerHeight =
            dim.height - dim.margin.top - dim.margin.bottom

        allTimes =
            (List.map .recorded_at detail.boil_curves)
                ++ (List.map .recorded_at detail.float_events)

        ( minTime, maxTime ) =
            case ( List.sort allTimes, List.sort allTimes ) of
                ( [], [] ) ->
                    ( 0, 1 )

                ( a :: _, b :: _ ) ->
                    ( toFloat (Time.posixToMillis a), toFloat (Time.posixToMillis (List.reverse b |> List.head |> Maybe.withDefault a)) )

                _ ->
                    ( 0, 1 )

        timeRange =
            maxTime - minTime

        timeScale : Posix -> Float
        timeScale t =
            let
                millis =
                    toFloat (Time.posixToMillis t)
            in
            dim.margin.left + ((millis - minTime) / timeRange) * innerWidth

        tempMin =
            90.0

        tempMax =
            105.0

        tempScale : Float -> Float
        tempScale temp =
            dim.margin.top + (1 - (temp - tempMin) / (tempMax - tempMin)) * innerHeight

        floatScale : Float -> Float
        floatScale ratio =
            dim.margin.top + (1 - ratio / 100.0) * innerHeight

        threshold =
            detail.batch.target_temp - 2.0
    in
    div
        [ style "background" "white"
        , style "border-radius" "10px"
        , style "box-shadow" "0 2px 8px rgba(0,0,0,0.08)"
        , style "padding" "24px"
        , style "margin-bottom" "20px"
        , style "overflow-x" "auto"
        ]
        [ h3 [ style "margin" "0 0 16px 0", style "font-size" "16px" ]
            [ text "温度曲线 & 浮茧率 (双轴图)" ]
        , div [ style "margin-bottom" "12px" ]
            [ div [ style "display" "flex", style "gap" "20px", style "flex-wrap" "wrap" ]
                [ legendItem "#3b82f6" "●" ("温度 (°C)  目标: " ++ formatFloat detail.batch.target_temp ++ "°C")
                , legendItem "#10b981" "▲" "浮茧率 (%)"
                , legendItem "#ef4444" "---" ("低温阈值: " ++ formatFloat threshold ++ "°C")
                , legendItem "#fecaca" "█" "低温段"
                ]
            ]
        , svg
            [ SA.width (String.fromFloat dim.width)
            , SA.height (String.fromFloat dim.height)
            , viewBox ("0 0 " ++ String.fromFloat dim.width ++ " " ++ String.fromFloat dim.height)
            , style "width" "100%"
            , style "height" "auto"
            ]
            (List.concat
                [ underheatHighlight dim innerWidth innerHeight timeScale detail
                , gridLines dim innerWidth innerHeight tempMin tempMax
                , tempThresholdLine dim innerWidth threshold tempScale
                , tempCurve dim innerWidth innerHeight timeScale tempScale detail.boil_curves
                , floatPoints dim timeScale floatScale detail.float_events
                , tempAxis dim innerWidth innerHeight tempMin tempMax
                , floatAxis dim innerWidth innerHeight
                , timeAxis dim innerWidth innerHeight minTime maxTime
                ]
            )
        ]


legendItem : String -> String -> String -> Html msg
legendItem color icon label =
    div [ style "display" "flex", style "align-items" "center", style "gap" "6px", style "font-size" "13px", style "color" "#374151" ]
        [ span [ style "color" color, style "font-weight" "bold", style "font-size" "16px" ]
            [ text icon ]
        , text label
        ]


underheatHighlight : ChartDim -> Float -> Float -> (Posix -> Float) -> BatchDetail -> List (Svg msg)
underheatHighlight dim innerWidth innerHeight timeScale detail =
    List.map
        (\seg ->
            let
                x1 =
                    timeScale seg.start_time

                x2 =
                    timeScale seg.end_time
            in
            rect
                [ SA.x (String.fromFloat x1)
                , SA.y (String.fromFloat dim.margin.top)
                , SA.width (String.fromFloat (max (x2 - x1) 2))
                , SA.height (String.fromFloat innerHeight)
                , SA.fill "#fecaca"
                , SA.opacity "0.3"
                ]
                []
        )
        detail.underheat_segments


gridLines : ChartDim -> Float -> Float -> Float -> Float -> List (Svg msg)
gridLines dim innerWidth innerHeight tempMin tempMax =
    let
        tempSteps =
            [ 90, 92, 94, 96, 98, 100, 102, 104 ]

        tempScale temp =
            dim.margin.top + (1 - (temp - tempMin) / (tempMax - tempMin)) * innerHeight
    in
    List.map
        (\t ->
            line
                [ SA.x1 (String.fromFloat dim.margin.left)
                , SA.y1 (String.fromFloat (tempScale t))
                , SA.x2 (String.fromFloat (dim.margin.left + innerWidth))
                , SA.y2 (String.fromFloat (tempScale t))
                , SA.stroke "#e5e7eb"
                , SA.strokeWidth "1"
                ]
                []
        )
        tempSteps


tempThresholdLine : ChartDim -> Float -> Float -> (Float -> Float) -> List (Svg msg)
tempThresholdLine dim innerWidth threshold tempScale =
    [ line
        [ SA.x1 (String.fromFloat dim.margin.left)
        , SA.y1 (String.fromFloat (tempScale threshold))
        , SA.x2 (String.fromFloat (dim.margin.left + innerWidth))
        , SA.y2 (String.fromFloat (tempScale threshold))
        , SA.stroke "#ef4444"
        , SA.strokeWidth "2"
        , SA.strokeDasharray "8,4"
        ]
        []
    ]


tempCurve : ChartDim -> Float -> Float -> (Posix -> Float) -> (Float -> Float) -> List BoilCurve -> List (Svg msg)
tempCurve dim innerWidth innerHeight timeScale tempScale curves =
    let
        sorted =
            List.sortBy .recorded_at curves

        pathData =
            case sorted of
                [] ->
                    ""

                c :: rest ->
                    let
                        start =
                            "M " ++ String.fromFloat (timeScale c.recorded_at) ++ " " ++ String.fromFloat (tempScale c.temp_c)

                        restPath =
                            List.map
                                (\cv ->
                                    "L " ++ String.fromFloat (timeScale cv.recorded_at) ++ " " ++ String.fromFloat (tempScale cv.temp_c)
                                )
                                rest
                    in
                    start ++ " " ++ String.join " " restPath
    in
    [ Svg.path
        [ SA.d pathData
        , SA.fill "none"
        , SA.stroke "#3b82f6"
        , SA.strokeWidth "2.5"
        ]
        []
    , Svg.path
        [ SA.d pathData
        , SA.fill "none"
        , SA.stroke "#60a5fa"
        , SA.strokeWidth "5"
        , SA.opacity "0.2"
        ]
        []
    ]
        ++ (List.map
                (\c ->
                    circle
                        [ SA.cx (String.fromFloat (timeScale c.recorded_at))
                        , SA.cy (String.fromFloat (tempScale c.temp_c))
                        , SA.r "3"
                        , SA.fill "#3b82f6"
                        , SA.stroke "white"
                        , SA.strokeWidth "1.5"
                        ]
                        []
                )
                sorted
           )


floatPoints : ChartDim -> (Posix -> Float) -> (Float -> Float) -> List FloatEvent -> List (Svg msg)
floatPoints dim timeScale floatScale events =
    let
        sorted =
            List.sortBy .recorded_at events

        pathData =
            case sorted of
                [] ->
                    ""

                e :: rest ->
                    let
                        start =
                            "M " ++ String.fromFloat (timeScale e.recorded_at) ++ " " ++ String.fromFloat (floatScale e.float_ratio_pct)

                        restPath =
                            List.map
                                (\ev ->
                                    "L " ++ String.fromFloat (timeScale ev.recorded_at) ++ " " ++ String.fromFloat (floatScale ev.float_ratio_pct)
                                )
                                rest
                    in
                    start ++ " " ++ String.join " " restPath
    in
    [ Svg.path
        [ SA.d pathData
        , SA.fill "none"
        , SA.stroke "#10b981"
        , SA.strokeWidth "2"
        , SA.strokeDasharray "4,2"
        ]
        []
    ]
        ++ (List.map
                (\e ->
                    let
                        size =
                            if e.float_ratio_pct < 40 then
                                "6"

                            else
                                "4"

                        color =
                            if e.float_ratio_pct < 40 then
                                "#f59e0b"

                            else
                                "#10b981"
                    in
                    g []
                        [ polygon
                            [ SA.points
                                (let
                                    x =
                                        timeScale e.recorded_at

                                    y =
                                        floatScale e.float_ratio_pct

                                    s =
                                        if e.float_ratio_pct < 40 then
                                            7

                                        else
                                            5
                                 in
                                 String.fromFloat x
                                    ++ ","
                                    ++ String.fromFloat (y - s)
                                    ++ " "
                                    ++ String.fromFloat (x - s)
                                    ++ ","
                                    ++ String.fromFloat (y + s)
                                    ++ " "
                                    ++ String.fromFloat (x + s)
                                    ++ ","
                                    ++ String.fromFloat (y + s)
                                )
                            , SA.fill color
                            , SA.stroke "white"
                            , SA.strokeWidth "1.5"
                            ]
                            []
                        ]
                )
                sorted
           )


tempAxis : ChartDim -> Float -> Float -> Float -> Float -> List (Svg msg)
tempAxis dim innerWidth innerHeight tempMin tempMax =
    let
        tempSteps =
            [ 90, 95, 100, 105 ]

        tempScale temp =
            dim.margin.top + (1 - (temp - tempMin) / (tempMax - tempMin)) * innerHeight
    in
    [ line
        [ SA.x1 (String.fromFloat dim.margin.left)
        , SA.y1 (String.fromFloat dim.margin.top)
        , SA.x2 (String.fromFloat dim.margin.left)
        , SA.y2 (String.fromFloat (dim.margin.top + innerHeight))
        , SA.stroke "#6b7280"
        , SA.strokeWidth "1.5"
        ]
        []
    , text_
        [ SA.x (String.fromFloat (dim.margin.left - 45))
        , SA.y (String.fromFloat (dim.margin.top + innerHeight / 2))
        , SA.fill "#374151"
        , SA.fontSize "12"
        , SA.fontWeight "600"
        , SA.transform ("rotate(-90, " ++ String.fromFloat (dim.margin.left - 45) ++ ", " ++ String.fromFloat (dim.margin.top + innerHeight / 2) ++ ")")
        , SA.textAnchor "middle"
        ]
        [ text "温度 (°C)" ]
    ]
        ++ (List.map
                (\t ->
                    g []
                        [ line
                            [ SA.x1 (String.fromFloat (dim.margin.left - 5))
                            , SA.y1 (String.fromFloat (tempScale t))
                            , SA.x2 (String.fromFloat dim.margin.left)
                            , SA.y2 (String.fromFloat (tempScale t))
                            , SA.stroke "#6b7280"
                            , SA.strokeWidth "1.5"
                            ]
                            []
                        , text_
                            [ SA.x (String.fromFloat (dim.margin.left - 10))
                            , SA.y (String.fromFloat (tempScale t + 4))
                            , SA.fill "#374151"
                            , SA.fontSize "11"
                            , SA.textAnchor "end"
                            ]
                            [ text (String.fromInt t) ]
                        ]
                )
                tempSteps
           )


floatAxis : ChartDim -> Float -> Float -> List (Svg msg)
floatAxis dim innerWidth innerHeight =
    let
        rightX =
            dim.margin.left + innerWidth

        floatSteps =
            [ 0, 25, 50, 75, 100 ]

        floatScale ratio =
            dim.margin.top + (1 - ratio / 100.0) * innerHeight
    in
    [ line
        [ SA.x1 (String.fromFloat rightX)
        , SA.y1 (String.fromFloat dim.margin.top)
        , SA.x2 (String.fromFloat rightX)
        , SA.y2 (String.fromFloat (dim.margin.top + innerHeight))
        , SA.stroke "#6b7280"
        , SA.strokeWidth "1.5"
        ]
        []
    , text_
        [ SA.x (String.fromFloat (rightX + 45))
        , SA.y (String.fromFloat (dim.margin.top + innerHeight / 2))
        , SA.fill "#10b981"
        , SA.fontSize "12"
        , SA.fontWeight "600"
        , SA.transform ("rotate(90, " ++ String.fromFloat (rightX + 45) ++ ", " ++ String.fromFloat (dim.margin.top + innerHeight / 2) ++ ")")
        , SA.textAnchor "middle"
        ]
        [ text "浮茧率 (%)" ]
    ]
        ++ (List.map
                (\r ->
                    g []
                        [ line
                            [ SA.x1 (String.fromFloat rightX)
                            , SA.y1 (String.fromFloat (floatScale r))
                            , SA.x2 (String.fromFloat (rightX + 5))
                            , SA.y2 (String.fromFloat (floatScale r))
                            , SA.stroke "#6b7280"
                            , SA.strokeWidth "1.5"
                            ]
                            []
                        , text_
                            [ SA.x (String.fromFloat (rightX + 10))
                            , SA.y (String.fromFloat (floatScale r + 4))
                            , SA.fill "#374151"
                            , SA.fontSize "11"
                            ]
                            [ text (String.fromInt r) ]
                        ]
                )
                floatSteps
           )


timeAxis : ChartDim -> Float -> Float -> Float -> Float -> List (Svg msg)
timeAxis dim innerWidth innerHeight minTime maxTime =
    let
        bottomY =
            dim.margin.top + innerHeight

        timeRange =
            maxTime - minTime

        numTicks =
            6

        timeSteps =
            List.range 0 numTicks
                |> List.map (\i -> minTime + (toFloat i / toFloat numTicks) * timeRange)

        timeScale millis =
            dim.margin.left + ((millis - minTime) / timeRange) * innerWidth
    in
    [ line
        [ SA.x1 (String.fromFloat dim.margin.left)
        , SA.y1 (String.fromFloat bottomY)
        , SA.x2 (String.fromFloat (dim.margin.left + innerWidth))
        , SA.y2 (String.fromFloat bottomY)
        , SA.stroke "#6b7280"
        , SA.strokeWidth "1.5"
        ]
        []
    , text_
        [ SA.x (String.fromFloat (dim.margin.left + innerWidth / 2))
        , SA.y (String.fromFloat (bottomY + 45))
        , SA.fill "#374151"
        , SA.fontSize "12"
        , SA.fontWeight "600"
        , SA.textAnchor "middle"
        ]
        [ text "时间" ]
    ]
        ++ (List.map
                (\t ->
                    g []
                        [ line
                            [ SA.x1 (String.fromFloat (timeScale t))
                            , SA.y1 (String.fromFloat bottomY)
                            , SA.x2 (String.fromFloat (timeScale t))
                            , SA.y2 (String.fromFloat (bottomY + 5))
                            , SA.stroke "#6b7280"
                            , SA.strokeWidth "1.5"
                            ]
                            []
                        , text_
                            [ SA.x (String.fromFloat (timeScale t))
                            , SA.y (String.fromFloat (bottomY + 20))
                            , SA.fill "#374151"
                            , SA.fontSize "10"
                            , SA.textAnchor "middle"
                            ]
                            [ text (formatTimeShort (Time.millisToPosix (round t))) ]
                        ]
                )
                timeSteps
           )



-- UTILS


httpErrorToString : Http.Error -> String
httpErrorToString err =
    case err of
        Http.BadUrl s ->
            "无效URL: " ++ s

        Http.Timeout ->
            "请求超时"

        Http.NetworkError ->
            "网络错误"

        Http.BadStatus code ->
            "HTTP错误: " ++ String.fromInt code

        Http.BadBody s ->
            "响应解析错误: " ++ s


formatTime : Posix -> String
formatTime posix =
    let
        z =
            Time.utc

        y =
            String.fromInt (Time.toYear z posix)

        m =
            String.padLeft 2 '0' (String.fromInt (monthToInt (Time.toMonth z posix)))

        d =
            String.padLeft 2 '0' (String.fromInt (Time.toDay z posix))

        h =
            String.padLeft 2 '0' (String.fromInt (Time.toHour z posix))

        mi =
            String.padLeft 2 '0' (String.fromInt (Time.toMinute z posix))

        s =
            String.padLeft 2 '0' (String.fromInt (Time.toSecond z posix))
    in
    y ++ "-" ++ m ++ "-" ++ d ++ " " ++ h ++ ":" ++ mi ++ ":" ++ s


formatTimeShort : Posix -> String
formatTimeShort posix =
    let
        z =
            Time.utc

        m =
            String.padLeft 2 '0' (String.fromInt (monthToInt (Time.toMonth z posix)))

        d =
            String.padLeft 2 '0' (String.fromInt (Time.toDay z posix))

        h =
            String.padLeft 2 '0' (String.fromInt (Time.toHour z posix))

        mi =
            String.padLeft 2 '0' (String.fromInt (Time.toMinute z posix))
    in
    m ++ "-" ++ d ++ " " ++ h ++ ":" ++ mi


monthToInt : Time.Month -> Int
monthToInt m =
    case m of
        Time.Jan ->
            1

        Time.Feb ->
            2

        Time.Mar ->
            3

        Time.Apr ->
            4

        Time.May ->
            5

        Time.Jun ->
            6

        Time.Jul ->
            7

        Time.Aug ->
            8

        Time.Sep ->
            9

        Time.Oct ->
            10

        Time.Nov ->
            11

        Time.Dec ->
            12


formatFloat : Float -> String
formatFloat f =
    String.fromFloat (toFloat (round (f * 100)) / 100)


styleList : List ( String, String ) -> Attribute msg
styleList =
    String.join "; " << List.map (\( k, v ) -> k ++ ": " ++ v) >> style
