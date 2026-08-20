# Build context = vmpilot-webui/ root (see docker-compose.yml)
# No-build frontend: static ES modules + vendored UMD libs are served as-is.
FROM nginx:1.27-alpine
RUN apk add --no-cache openssl bash
COPY nginx/nginx.conf /etc/nginx/conf.d/vmpilot.conf
COPY nginx/headers.conf /etc/nginx/conf.d/headers.conf
COPY nginx/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && rm -f /etc/nginx/conf.d/default.conf
# Static frontend only: entry HTML + css/js/vendor. No build step, no node_modules.
COPY frontend/index.html /usr/share/nginx/html/index.html
COPY frontend/css /usr/share/nginx/html/css
COPY frontend/js /usr/share/nginx/html/js
COPY frontend/vendor /usr/share/nginx/html/vendor
EXPOSE 80 443
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]