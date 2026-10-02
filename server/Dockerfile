FROM oven/bun:1-alpine
WORKDIR /app
COPY package.json bun.lock* ./
RUN bun install --production
COPY src ./src
ENV DB_PATH=/data/relay.db PORT=8080
RUN mkdir -p /data && chown bun:bun /data
VOLUME /data
EXPOSE 8080
USER bun
CMD ["bun", "run", "src/index.ts"]
