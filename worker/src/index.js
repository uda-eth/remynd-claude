// Serves the ReMynd × Claude Code installer at remyndai.com/claude/install.sh
// by proxying the canonical script from GitHub. Only claims /claude/* on the zone.
const INSTALL_URL = "https://raw.githubusercontent.com/uda-eth/remynd-claude/main/install.sh";

export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);
    if (pathname === "/claude/install.sh") {
      const upstream = await fetch(INSTALL_URL, { cf: { cacheTtl: 300, cacheEverything: true } });
      return new Response(upstream.body, {
        status: upstream.status,
        headers: {
          "content-type": "text/x-shellscript; charset=utf-8",
          "cache-control": "public, max-age=300",
          "x-remynd-claude": "installer",
        },
      });
    }
    // Any other /claude/* path → the repo.
    return Response.redirect("https://github.com/uda-eth/remynd-claude", 302);
  },
};
