# Tools container: DesktopCommander (files and terminal) wrapped into
# streamable HTTP by supergateway. One container for all bots.
FROM node:22-bookworm-slim

# ripgrep is a system package: DesktopCommander finds it in PATH.
# python3 is for vault checks (notes/scripts/verify.py).
# curl downloads web pages (Jina Reader) and PDFs into files, poppler-utils (pdftotext)
# converts the PDFs to text; the bots then search these files with ripgrep.
# npm packages are installed with --ignore-scripts: the DesktopCommander postinstall
# sends installation data to a telemetry server, and puppeteer (a dependency of PDF
# generation) downloads a browser; neither is needed.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git openssh-client ca-certificates ripgrep python3 curl poppler-utils \
    && rm -rf /var/lib/apt/lists/*

# Versions are pinned; upgrades are deliberate (see CLAUDE.md).
RUN npm install -g --ignore-scripts \
    @wonderwhy-er/desktop-commander@0.3.3 \
    supergateway@4.2.2 \
    && npm cache clean --force

WORKDIR /opt/parley
COPY init-config.mjs entrypoint.sh ./
RUN chmod +x entrypoint.sh

EXPOSE 8000
ENTRYPOINT ["/opt/parley/entrypoint.sh"]
