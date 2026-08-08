-include .env

REPO ?= wodby/edge-alpine
NAME ?= edge-alpine
TAG ?= latest
IMAGE := $(REPO):$(TAG)
PLATFORM ?=
PLATFORM_ARG = $(if $(PLATFORM),--platform=$(PLATFORM),)

.PHONY: default build test push shell clean release

default: build

build:
	docker build $(PLATFORM_ARG) --pull --progress=plain -t $(IMAGE) ./

test:
	IMAGE=$(IMAGE) ./tests/run.sh

push:
	docker push $(IMAGE)

shell:
	docker run --rm --name $(NAME) -it $(PORTS) $(VOLUMES) $(ENV) $(IMAGE) /bin/bash

clean:
	-docker rm -f $(NAME)

release: build push
