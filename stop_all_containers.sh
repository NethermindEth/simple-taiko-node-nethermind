#!/bin/bash
docker compose -f docker-compose-hekla-preconfer.yml down taiko_client_proposer
sleep 1
docker compose -f docker-compose-hekla-preconfer.yml down -v