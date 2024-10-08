ARG IMAGE_TARGET=latest
FROM --platform=$BUILDPLATFORM golang:alpine AS build

WORKDIR /src/samba_exporter

RUN apk --no-cache --no-progress upgrade && \
    apk --no-cache --no-progress add ronn bash git

COPY . /src/
ARG TARGETOS TARGETARCH TARGETVARIENT
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg \
    GOOS=$TARGETOS GOARCH=$TARGETARCH GOARM="${TARGETVARIENT:1}" ./build.sh preparePack

RUN mkdir -p /dist/usr && \
    bash -c "mv tmp/samba-exporter_*/usr/bin /dist/usr/bin"

# ==============================================

FROM alpine AS latest_image

# Install samba
RUN apk --no-cache --no-progress upgrade && \
    apk --no-cache --no-progress add bash samba shadow supervisor tzdata && \
    addgroup -S smb && \
    adduser -S -D -H -h /tmp -s /sbin/nologin -G smb -g 'Samba User' smbuser

RUN cp -r /var/lib/samba /samba.bak

ENV SMB_CONF_PATH=/etc/docker-samba/smb.conf

# Default config
RUN file="/etc/samba/smb.conf" && \
    sed -i 's|^;* *\(log file = \).*|   \1/dev/stdout|' $file && \
    sed -i 's|^;* *\(load printers = \).*|   \1no|' $file && \
    sed -i 's|^;* *\(printcap name = \).*|   \1/dev/null|' $file && \
    sed -i 's|^;* *\(printing = \).*|   \1bsd|' $file && \
    sed -i 's|^;* *\(unix password sync = \).*|   \1no|' $file && \
    sed -i 's|^;* *\(preserve case = \).*|   \1yes|' $file && \
    sed -i 's|^;* *\(short preserve case = \).*|   \1yes|' $file && \
    sed -i 's|^;* *\(default case = \).*|   \1lower|' $file && \
    sed -i '/Share Definitions/,$d' $file && \
    echo '   pam password change = yes' >>$file && \
    echo '   map to guest = bad user' >>$file && \
    echo '   usershare allow guests = yes' >>$file && \
    echo '   create mask = 0664' >>$file && \
    echo '   force create mode = 0664' >>$file && \
    echo '   directory mask = 0775' >>$file && \
    echo '   force directory mode = 0775' >>$file && \
    echo '   force user = smbuser' >>$file && \
    echo '   force group = smb' >>$file && \
    echo '   follow symlinks = yes' >>$file && \
    echo '   load printers = no' >>$file && \
    echo '   printing = bsd' >>$file && \
    echo '   printcap name = /dev/null' >>$file && \
    echo '   disable spoolss = yes' >>$file && \
    echo '   strict locking = no' >>$file && \
    echo '   aio read size = 0' >>$file && \
    echo '   aio write size = 0' >>$file && \
    echo '   vfs objects = catia fruit recycle streams_xattr' >>$file && \
    echo '   recycle:keeptree = yes' >>$file && \
    echo '   recycle:maxsize = 0' >>$file && \
    echo '   recycle:repository = .deleted' >>$file && \
    echo '   recycle:versions = yes' >>$file && \
    echo '' >>$file && \
    echo '   # Security' >>$file && \
    echo '   client ipc max protocol = SMB3' >>$file && \
    echo '   client ipc min protocol = SMB2_10' >>$file && \
    echo '   client max protocol = SMB3' >>$file && \
    echo '   client min protocol = SMB2_10' >>$file && \
    echo '   server max protocol = SMB3' >>$file && \
    echo '   server min protocol = SMB2_10' >>$file && \
    echo '' >>$file && \
    echo '   # Time Machine' >>$file && \
    echo '   fruit:delete_empty_adfiles = yes' >>$file && \
    echo '   fruit:time machine = yes' >>$file && \
    echo '   fruit:veto_appledouble = no' >>$file && \
    echo '   fruit:wipe_intentionally_left_blank_rfork = yes' >>$file && \
    echo '' >>$file && \
    mkdir /etc/docker-samba && \
    mkdir -p /etc/supervisor/conf.d && \
    cp /etc/samba/smb.conf $SMB_CONF_PATH && \
    rm -rf /tmp/*

COPY supervisord.conf /dist/etc/supervisor/conf.d/
COPY usr/bin/entrypoint.sh /usr/bin/
COPY usr/bin/samba.sh /usr/bin/

ARG IMAGE_TARGET
ENV IMAGE_TARGET=$IMAGE_TARGET

HEALTHCHECK --interval=60s --timeout=15s \
    CMD smbclient -L \\localhost -U % -m SMB3

# ==============================================

FROM latest_image AS exporter_image

RUN apk --no-cache --no-progress add python3 && \
    addgroup -S samba-exporter && \
    adduser -S -H -D -G samba-exporter samba-exporter

COPY exporter-supervisord.conf /dist/etc/supervisor/conf.d/
RUN cat /dist/etc/supervisor/conf.d/exporter-supervisord.conf >>/dist/etc/supervisor/conf.d/supervisord.conf

COPY /usr/bin/exporter_dependant_start.py /usr/bin/

COPY --from=build /dist/ /
RUN sed -i "s/\$samba_statusd \$\* &/exec \$samba_statusd \$*/g" '/usr/bin/start_samba_statusd'

EXPOSE 9922

HEALTHCHECK --interval=20s \
    CMD smbclient -L \\localhost -U % -m SMB3 && \
    bash -c '[[ "$(wget --spider -S "$(cat /tmp/exporter-healthcheck-url)" 2>&1 | grep "HTTP/" | awk "{print \$2}")" == "200" ]]'

# ==============================================

FROM ${IMAGE_TARGET}_image AS final

EXPOSE 137/udp 138/udp 139 445


VOLUME ["/etc", "/var/cache/samba", "/var/lib/samba", "/var/log/samba",\
    "/run/samba"]

ENTRYPOINT ["/usr/bin/entrypoint.sh"]
