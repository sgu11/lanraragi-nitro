ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG SOURCE_REVISION
LABEL org.opencontainers.image.revision=${SOURCE_REVISION}
LABEL com.centurylinklabs.watchtower.enable=false
ENV WORKER_SOURCE_REVISION=${SOURCE_REVISION} \
    PERL5LIB=/opt/adaptive-offset/lib:/home/koyomi/perl5/lib/perl5 \
    MOJO_MODE=production \
    VIPS_CONCURRENCY=1 \
    MALLOC_ARENA_MAX=2
WORKDIR /opt/adaptive-offset
COPY lib/LANraragi/Utils/Vips.pm lib/LANraragi/Utils/PageSideDetector.pm lib/LANraragi/Utils/AdaptiveOffsetVote.pm lib/LANraragi/Utils/AdaptiveOffsetWorker.pm ./lib/LANraragi/Utils/
COPY script/adaptive-offset-worker ./script/adaptive-offset-worker
USER 10001:10001
ENTRYPOINT []
CMD ["perl", "script/adaptive-offset-worker"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD perl -MMojo::UserAgent -e 'exit(Mojo::UserAgent->new->request_timeout(3)->get("http://127.0.0.1:8766/health")->result->is_success ? 0 : 1)'
