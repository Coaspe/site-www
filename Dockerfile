FROM ruby:3.2-slim-bullseye@sha256:931af3418a0d1cca687691e183554960d5ee0e95ea3dd4f92b3a820c383c5320 as base

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=US/Pacific
RUN apt update && apt install -yq --no-install-recommends \
  build-essential \
  ca-certificates \
  curl \
  git \
  lsof \
  make \
  unzip \
  vim-nox \
  && rm -rf /var/lib/apt/lists/*

RUN echo "alias lla='ls -lAhG --color=auto'" >> ~/.bashrc
WORKDIR /root


# google-chrome-stable


# ============== DART ==============
# See https://github.com/dart-lang/dart-docker
# See https://github.com/dart-lang/setup-dart/blob/main/setup.sh
FROM base as dart
ARG DART_VERSION=latest
ARG DART_CHANNEL=stable
ENV DART_VERSION=$DART_VERSION
ENV DART_CHANNEL=$DART_CHANNEL
ENV DART_SDK=/usr/lib/dart
ENV PATH=$DART_SDK/bin:$PATH
RUN set -eu; \
  case "$(dpkg --print-architecture)_${DART_CHANNEL}" in \
  amd64_stable) \
  DART_SHA256="337de0ad3ee66dca7ffa81fc3cd9ecd53d4593384da9d1dfcf4b68f69559fa2b"; \
  SDK_ARCH="x64";; \
  arm64_stable) \
  DART_SHA256="684092802f280ca7a64b111da647bbd380d2ce5adf8a23bcd70cc902a3c4a495"; \
  SDK_ARCH="arm64";; \
  amd64_beta) \
  DART_SHA256="a7154a06224168546f75b7f6294e9630f18da7ab33d28912a1bc5fab076f9da4"; \
  SDK_ARCH="x64";; \
  arm64_beta) \
  DART_SHA256="edc4bf48b3bc3999caf8c3093dffffb960369699bc5ab912ebfd153cf02cbd35"; \
  SDK_ARCH="arm64";; \
  amd64_dev) \
  DART_SHA256="221a06947f3918d02ce0c3e47a479e03ac46d0eb758b569c2995616bd23a618b"; \
  SDK_ARCH="x64";; \
  arm64_dev) \
  DART_SHA256="9c62c518ad7bd9789b85d7e47fdbdbeb9dc228e6bad2602888a422594313d908"; \
  SDK_ARCH="arm64";; \
  esac; \
  SDK="dartsdk-linux-${SDK_ARCH}-release.zip"; \
  BASEURL="https://storage.googleapis.com/dart-archive/channels"; \
  URL="$BASEURL/$DART_CHANNEL/release/$DART_VERSION/sdk/$SDK"; \
  curl -fsSLO "$URL"; \
  echo "$DART_SHA256 *$SDK" | sha256sum --check --status --strict - || (\
  echo -e "\n\nDART CHECKSUM FAILED! Run 'make fetch-sums' for updated values.\n\n" && \
  rm "$SDK" && \
  exit 1 \
  ); \
  unzip "$SDK" > /dev/null && mv dart-sdk "$DART_SDK" && rm "$SDK";
ENV PUB_CACHE="${HOME}/.pub-cache"
RUN dart --disable-analytics
RUN echo -e "Successfully installed Dart SDK:" && dart --version


# ============== DART-TESTS ==============
from dart as dart-tests
WORKDIR /app
COPY ./ ./
RUN dart pub get
ENV BASE_DIR=/app
ENV TOOL_DIR=$BASE_DIR/tool
CMD ["./tool/test.sh"]


# ============== NODEJS INSTALL ==============
FROM dart as node
RUN set -eu; \
  NODE_PPA="node_ppa.sh"; \
  NODE_SHA256=061519c83ce8799cc00d36e3bab85ffcb9a8b4164c57b536cc2837048de9939f; \
  curl -fsSL https://deb.nodesource.com/setup_lts.x -o "$NODE_PPA"; \
  echo "$NODE_SHA256 $NODE_PPA" | sha256sum --check --status --strict - || (\
  echo -e "\n\nNODE CHECKSUM FAILED! Run tool/fetch-node-ppa-sum.sh for updated values.\n\n" && \
  rm "$NODE_PPA" && \
  exit 1 \
  ); \
  sh "$NODE_PPA" && rm "$NODE_PPA"; \
  apt-get update -q && apt-get install -yq --no-install-recommends \
  nodejs \
  && rm -rf /var/lib/apt/lists/*
# Ensure latest NPM
RUN npm install -g npm


# ============== DEV/JEKYLL SETUP ==============
FROM node as dev
WORKDIR /app

ENV JEKYLL_ENV=development
COPY Gemfile Gemfile.lock ./
RUN gem update --system && gem install bundler
RUN BUNDLE_WITHOUT="test production" bundle install --jobs=4 --retry=2

ENV NODE_ENV=development
COPY package.json package-lock.json ./
RUN npm install -g firebase-tools@11.19.0
RUN npm install

COPY ./ ./

# Ensure packages are still up-to-date if anything has changed
# RUN dart pub get --offline
RUN dart pub get

# Let's not play "which dir is this"
ENV BASE_DIR=/app
ENV TOOL_DIR=$BASE_DIR/tool

# Jekyl
EXPOSE 4000
EXPOSE 35729

# Firebase emulator port
# Airplay runs on :5000 by default now
EXPOSE 5500 

# re-enable defult in case we want to test packages
ENV DEBIAN_FRONTEND=dialog


# ============== FIREBASE EMULATE ==============
FROM dev as emulate
RUN bundle exec jekyll build --config _config.yml,_config_test.yml
CMD ["make", "emulate"]


# ============== BUILD PROD JEKYLL SITE ==============
FROM node AS build
WORKDIR /app

ENV JEKYLL_ENV=production
COPY Gemfile Gemfile.lock ./
RUN gem update --system && gem install bundler
RUN BUNDLE_WITHOUT="test development" bundle install --jobs=4 --retry=2 --quiet

ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm install

COPY ./ ./

RUN dart pub get

ENV BASE_DIR=/app
ENV TOOL_DIR=$BASE_DIR/tool

ARG BUILD_CONFIGS=_config.yml
ENV BUILD_CONFIGS=$BUILD_CONFIGS
RUN bundle exec jekyll build --config $BUILD_CONFIGS


# ============== DEPLOY to FIREBASE ==============
FROM build as deploy
RUN npm install -g firebase-tools@11.19.0
ARG FIREBASE_TOKEN
ENV FIREBASE_TOKEN=$FIREBASE_TOKEN
ARG FIREBASE_PROJECT=default
ENV FIREBASE_PROJECT=$FIREBASE_PROJECT
RUN [[ -z "$FIREBASE_TOKEN" ]] && echo "FIREBASE_TOKEN is required for container deploy!"
RUN make deploy-ci
