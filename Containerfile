FROM ruby:3.4-slim

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libmariadb-dev \
    && rm -rf /var/lib/apt/lists/*

# build the gem
WORKDIR /app
COPY . .
RUN gem build
RUN gem install --no-document *.gem

