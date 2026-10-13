FROM alpine:3.20
RUN apk add --no-cache bash arp-scan
COPY scan.sh /scan.sh
RUN chmod +x /scan.sh
CMD ["/scan.sh"]
