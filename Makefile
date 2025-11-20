.PHONY: up down

up:
	./script/update-timestamp-and-compose.sh

down:
	docker compose down -v

