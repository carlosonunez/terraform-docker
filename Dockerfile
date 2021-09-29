FROM ubuntu AS build
RUN apt -y update
RUN apt -y install curl unzip

FROM build AS app
LABEL maintainer="Carlos Nunez <dev@carlosnunez.me>"
LABEL repository="https://github.com/carlosonunez/terraform-docker"
ARG ARCH
ARG VERSION
ENV TERRAFORM_URL="https://releases.hashicorp.com/terraform/$VERSION/terraform_${VERSION}_linux_${ARCH}.zip"

RUN apt -y update
RUN apt -y install git wget

RUN curl -o /terraform.zip "$TERRAFORM_URL" && \
  unzip /terraform.zip && \
  chmod +x /terraform && \
  mv /terraform /usr/local/bin

ENTRYPOINT [ "terraform" ]
