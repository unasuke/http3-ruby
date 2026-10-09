# The quic-interop-runner endpoint image (server role). Build from the
# repository root:
#
#   docker build -f test/interop/Dockerfile -t http3-ruby-interop .

# setup.sh and wait-for-it.sh come from the simulator's endpoint image, which
# does not have the Ruby http3 needs.
FROM martenseemann/quic-network-simulator-endpoint:latest AS endpoint

FROM ruby:4.0-bookworm
RUN apt-get update \
  && apt-get install -y --no-install-recommends autoconf automake libtool pkg-config iproute2 ethtool net-tools \
  && rm -rf /var/lib/apt/lists/*
COPY --from=endpoint /setup.sh /wait-for-it.sh /

WORKDIR /http3
COPY . .
# The context may hold the host's Bundler settings (a local.quic override,
# say) and build; neither belongs in the image.
RUN rm -rf .bundle && bundle install && bundle exec rake clobber compile

COPY test/interop/run_endpoint.sh /run_endpoint.sh
RUN chmod +x /run_endpoint.sh
ENTRYPOINT ["/run_endpoint.sh"]
