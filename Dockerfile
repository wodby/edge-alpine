FROM wodby/edge-alpine:1.3.1

ENV LEGO_VER="v0.4.0" \
    NGINX_VER="1.15.9" \
    NGINX_UP_VER="0.9.1" \
    APP_ROOT="/var/www/html" \
    FILES_DIR="/mnt/files" \
    NGINX_VHOST_PRESET="html" \
    OWASP_CRS_VER="3.1.0"

RUN set -ex; \
    \
    # Upgrade alpine
    apk add --update busybox-static apk-tools-static; \
    sed -i -e 's/v3\.4/v3.9/g' /etc/apk/repositories; \
    \
    apk.static update; \
    apk.static upgrade --no-self-upgrade --available; \
    \
    apk add --update --no-cache \
        bash \
        ca-certificates \
        curl \
        gzip \
        tar \
        unzip \
        wget; \
    \
    # Install gotpl
    \
    gotpl_url="https://github.com/wodby/gotpl/releases/download/0.1.5/gotpl-alpine-linux-amd64-0.1.5.tar.gz"; \
    wget -qO- "${gotpl_url}" | tar xz -C /usr/local/bin; \
    \
    # Install Lego
    wget -qO- https://s3.amazonaws.com/wodby-releases/lego/${LEGO_VER}/lego.tar.gz | tar xz -C /tmp/; \
    mkdir -p /opt/wodby/bin; \
    mv /tmp/lego /opt/wodby/bin; \
    \
    # Build and install nginx
    \
    apk add --update --no-cache -t .tools \
        findutils \
        make \
        nghttp2 \
        sudo; \
    \
    apk add --update --no-cache -t .nginx-build-deps \
        apr-dev \
        apr-util-dev \
        build-base \
        gd-dev \
        git \
        gnupg \
        gperf \
        icu-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        libressl-dev \
        libtool \
        libxslt-dev \
        linux-headers \
        pcre-dev \
        zlib-dev; \
     \
    # Get ngx uploadprogress module.
    mkdir -p /tmp/ngx_http_uploadprogress_module; \
    url="https://github.com/masterzen/nginx-upload-progress-module/archive/v${NGINX_UP_VER}.tar.gz"; \
    wget -qO- "${url}" | tar xz --strip-components=1 -C /tmp/ngx_http_uploadprogress_module; \
    \
    # Download nginx.
    curl -fSL "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz" -o /tmp/nginx.tar.gz; \
    curl -fSL "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz.asc"  -o /tmp/nginx.tar.gz.asc; \
    tar zxf /tmp/nginx.tar.gz -C /tmp; \
    \
    cd "/tmp/nginx-${NGINX_VER}"; \
    ./configure \
        --prefix=/usr/share/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --pid-path=/var/run/nginx/nginx.pid \
        --lock-path=/var/run/nginx/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-compat \
        --with-file-aio \
        --with-http_addition_module \
        --with-http_auth_request_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
		--with-http_image_filter_module=dynamic \
        --with-http_mp4_module \
        --with-http_random_index_module \
        --with-http_realip_module \
        --with-http_secure_link_module \
		--with-http_slice_module \
        --with-http_ssl_module \
        --with-http_stub_status_module \
        --with-http_sub_module \
        --with-http_v2_module \
		--with-http_xslt_module=dynamic \
        --with-ipv6 \
        --with-ld-opt="-Wl,-z,relro,--start-group -lapr-1 -laprutil-1 -licudata -licuuc -lpng -lturbojpeg -ljpeg" \
        --with-mail \
        --with-mail_ssl_module \
        --with-pcre-jit \
        --with-stream \
        --with-stream_ssl_module \
		--with-stream_ssl_preread_module \
		--with-stream_realip_module \
        --with-threads \
        --add-module=/tmp/ngx_http_uploadprogress_module ; \
    \
    make -j$(getconf _NPROCESSORS_ONLN); \
    make install; \
    mkdir -p /usr/share/nginx/modules; \
    \
    install -g wodby -o wodby -d \
        "${APP_ROOT}" \
        "${FILES_DIR}" \
        /etc/nginx/conf.d \
        /var/cache/nginx \
        /var/lib/nginx; \
    \
    touch /etc/nginx/upstream.conf; \
    \
    install -m 400 -d /etc/nginx/pki; \
    strip /usr/sbin/nginx*; \
    strip /usr/lib/nginx/modules/*.so; \
    \
    for i in /usr/lib/nginx/modules/*.so; do ln -s "${i}" /usr/share/nginx/modules/; done; \
    \
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' /usr/sbin/nginx /usr/lib/nginx/modules/*.so /tmp/envsubst \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)"; \
	apk add --no-cache --virtual .nginx-rundeps $runDeps; \
    \
    apk del --purge .nginx-build-deps; \
    rm -rf \
        /tmp/* \
        /var/cache/apk/* ;

COPY rootfs /
