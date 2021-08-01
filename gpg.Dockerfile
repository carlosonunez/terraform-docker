FROM ubuntu:latest
MAINTAINER Carlos Nunez <dev@carlosnunez.me>

RUN apt-get -y update && apt-get -y install gnupg zip
