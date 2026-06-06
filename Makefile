.PHONY: db start-backend build-frontend build-all run clean

db:
	docker-compose up -d db

build-backend:
	cd backend && cargo build --release

build-frontend:
	cd frontend && elm make src/Main.elm --output=dist/main.js --optimize

build-all: build-backend build-frontend

run-backend:
	cd backend && cargo run

dev-backend:
	cd backend && cargo watch -x run

clean:
	cd backend && cargo clean
	rm -rf frontend/dist frontend/main.js frontend/elm-stuff
