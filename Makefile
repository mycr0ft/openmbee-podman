# OpenMBEE Flexo MMS + SysML v2 API on podman-compose.
COMPOSE = podman-compose -p openmbee
SHELL   = /bin/bash

.PHONY: help up down reset status logs seed verify token login ps shell

help:            ## this list
	@grep -hE '^[a-z]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t18
up:              ## create .env if needed, start everything, seed, wait until usable
	./bin/bootstrap.sh
down:            ## stop containers, keep data
	$(COMPOSE) down
reset:           ## stop containers and delete all data (LDAP, TDB2, MinIO)
	$(COMPOSE) down -v
status:          ## container states and published ports
	$(COMPOSE) ps
logs:            ## follow all logs
	$(COMPOSE) logs -f
ps: status
verify:          ## end-to-end gate: auth, org/project, JSON, notation, persistence
	./bin/verify.sh
seed:            ## (re)load mount/cluster.trig if the cluster graph is missing
	./bin/seed.sh
token:           ## print the long-lived bearer token
	@python3 bin/envset.py .env FLEXO_AUTH
login:           ## interactive: demo-user token from auth-service
	@curl -s -u "$$(python3 bin/envset.py .env DEMO_USER):$$(python3 bin/envset.py .env DEMO_PASSWORD)" \
		"http://$$(python3 bin/envset.py .env BIND_ADDR):$$(python3 bin/envset.py .env AUTH_PORT 8082)/login"; echo
shell:           ## shell in a service, e.g. make shell S=layer1-service
	$(COMPOSE) exec $(S) /bin/sh
