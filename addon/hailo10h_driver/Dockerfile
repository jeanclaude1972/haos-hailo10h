ARG BUILD_FROM
FROM ${BUILD_FROM}

# firmware/: Hailo-10H firmware 5.1.1 (not redistributable; see firmware/README.md).
# bundled/: optional prebuilt module + its kernel.release, used if no download fits.
COPY firmware/ /opt/hailo/firmware/
COPY bundled/ /opt/hailo/bundled/
COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD ["/run.sh"]
