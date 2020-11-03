# https://docs.ghost.org/faq/node-versions/
# https://github.com/nodejs/LTS
FROM node:8-slim

# grab gosu for easy step-down from root
ENV GOSU_VERSION 1.10
RUN set -x \
	&& wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$(dpkg --print-architecture)" \
	&& wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$(dpkg --print-architecture).asc" \
	&& export GNUPGHOME="$(mktemp -d)" \
	&& gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 \
	&& gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu \
	&& { command -v gpgconf && gpgconf --kill all || :; } \
	&& rm -r "$GNUPGHOME" /usr/local/bin/gosu.asc \
	&& chmod +x /usr/local/bin/gosu \
	&& gosu nobody true

ENV NODE_ENV production

ENV GHOST_CLI_VERSION 1.11.0
RUN set -eux; \
	npm install -g "ghost-cli@$GHOST_CLI_VERSION"; \
	npm cache clean --force

ENV GHOST_INSTALL /var/lib/ghost
ENV GHOST_CONTENT /var/lib/ghost/content

ENV GHOST_VERSION 2.2.4
ENV GHOST_PORT 2368

RUN set -eux; \
	mkdir -p "$GHOST_INSTALL"; \
	chown node:node "$GHOST_INSTALL"; \
	\
	gosu node ghost install "$GHOST_VERSION" --db sqlite3 --no-prompt --no-stack --no-setup --dir "$GHOST_INSTALL"; \
	\
# Tell Ghost to listen on all ips and not prompt for additional configuration
	cd "$GHOST_INSTALL"; \
	gosu node ghost config --ip 0.0.0.0 --port $GHOST_PORT --no-prompt --db sqlite3 --url http://localhost:$GHOST_PORT --dbpath "$GHOST_CONTENT/data/ghost.db"; \
	gosu node ghost config paths.contentPath "$GHOST_CONTENT"; \
	\
# make a config.json symlink for NODE_ENV=development (and sanity check that it's correct)
	gosu node ln -s config.production.json "$GHOST_INSTALL/config.development.json"; \
	readlink -f "$GHOST_INSTALL/config.development.json"; \
	\
# need to save initial content for pre-seeding empty volumes
	mv "$GHOST_CONTENT" "$GHOST_INSTALL/content.orig"; \
	mkdir -p "$GHOST_CONTENT"; \
	chown node:node "$GHOST_CONTENT"; \
	\
# force install "sqlite3" manually since it's an optional dependency of "ghost"
# (which means that if it fails to install, like on ARM/ppc64le/s390x, the failure will be silently ignored and thus turn into a runtime error instead)
# see https://github.com/TryGhost/Ghost/pull/7677 for more details
	cd "$GHOST_INSTALL/current"; \
# scrape the expected version of sqlite3 directly from Ghost itself
	sqlite3Version="$(npm view . optionalDependencies.sqlite3)"; \
	if ! gosu node yarn add "sqlite3@$sqlite3Version" --force; then \
# must be some non-amd64 architecture pre-built binaries aren't published for, so let's install some build deps and do-it-all-over-again
		savedAptMark="$(apt-mark showmanual)"; \
		apt-get update; \
		apt-get install -y --no-install-recommends python make gcc g++ libc-dev; \
		rm -rf /var/lib/apt/lists/*; \
		\
		gosu node yarn add "sqlite3@$sqlite3Version" --force --build-from-source; \
		\
		apt-mark showmanual | xargs apt-mark auto > /dev/null; \
		[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
		apt-get purge -y --auto-remove; \
	fi; \
	\
	gosu node yarn cache clean; \
	gosu node npm cache clean --force; \
	npm cache clean --force; \
	rm -rv /tmp/yarn* /tmp/v8*

COPY ghost.db /var/lib/ghost/content/data/ghost.db

WORKDIR $GHOST_INSTALL
VOLUME $GHOST_CONTENT

COPY docker-entrypoint.sh /usr/local/bin
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE $GHOST_PORT
CMD ["node", "current/index.js"]

