FROM node:22-alpine
WORKDIR /app
COPY server.js .
ENV DATA_DIR=/data PORT=8787
VOLUME /data
EXPOSE 8787
USER node
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8787/api/health || exit 1
CMD ["node", "server.js"]
