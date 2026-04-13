# ============================================================
# Nexus Repository Nginx Reverse Proxy
# 위치: /etc/nginx/conf.d/nexus.conf
# ============================================================

upstream nexus_backend {
    server 127.0.0.1:${NEXUS_HTTP_PORT};
    keepalive 32;
}

server {
    listen       ${NGINX_LISTEN_PORT};
    server_name  ${NGINX_SERVER_NAME};

    # 대용량 파일 업로드 (20GB + 여유)
    client_max_body_size 25g;

    # 프록시 타임아웃 (대용량 전송)
    proxy_connect_timeout 300;
    proxy_send_timeout    600;
    proxy_read_timeout    600;
    send_timeout          600;

    # 프록시 버퍼
    proxy_buffering off;
    proxy_request_buffering off;

    location / {
        proxy_pass http://nexus_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Websocket (Nexus UI)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Health check endpoint
    location /service/rest/v1/status {
        proxy_pass http://nexus_backend;
        proxy_set_header Host $host;
        access_log off;
    }
}
