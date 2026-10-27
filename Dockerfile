FROM ubuntu:22.04
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        gcc-arm-linux-gnueabi make && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY src/ src/
COPY Makefile .
RUN make CC=arm-linux-gnueabi-gcc
