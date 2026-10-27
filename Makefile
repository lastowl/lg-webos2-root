CC ?= arm-linux-gnueabi-gcc
CFLAGS = -static -O2 -Wall
LDFLAGS = -static -lpthread
BUILD_DIR = build

BINS = $(BUILD_DIR)/towelroot $(BUILD_DIR)/rootsh $(BUILD_DIR)/dotrigger

all: $(BINS)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/towelroot: src/towelroot.c src/kernels.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

$(BUILD_DIR)/rootsh: src/rootsh.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD_DIR)/dotrigger: src/dotrigger.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $<

docker-build:
	docker build -t lg-webos-root-builder .
	docker create --name lg-webos-extract lg-webos-root-builder true
	mkdir -p $(BUILD_DIR)
	docker cp lg-webos-extract:/build/$(BUILD_DIR)/towelroot $(BUILD_DIR)/
	docker cp lg-webos-extract:/build/$(BUILD_DIR)/rootsh $(BUILD_DIR)/
	docker cp lg-webos-extract:/build/$(BUILD_DIR)/dotrigger $(BUILD_DIR)/
	docker rm lg-webos-extract
	@echo "Binaries in $(BUILD_DIR)/"

clean:
	rm -rf $(BUILD_DIR)

deploy: all
	@echo "Usage: ./scripts/deploy.sh <tv-ip> [ssh-key] [port]"

.PHONY: all clean docker-build deploy
