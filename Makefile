-include .env

REPO = wodby/edge-alpine
NAME = edge-alpine
TAG ?= latest

default: build

build:
	docker build -t $(REPO):$(TAG) ./
.PHONY: build

push:
	docker push $(REPO):$(TAG)
.PHONY: push

shell:
	docker run --rm --name $(NAME) -i -t $(PORTS) $(VOLUMES) $(ENV) $(REPO):$(TAG) /bin/bash
.PHONY: shell

clean:
	-docker rm -f $(NAME)
.PHONY: clean

release: build push
.PHONY: release