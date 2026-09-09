const rateLimits = new Map<string, { count: number; resetAt: number }>();

export function rateLimit(
  handler: (ctx: any) => Promise<Response>,
  options: { windowMs: number; maxRequests: number }
) {
  return async (ctx: any): Promise<Response> => {
    const ip = ctx.req.headers.get('CF-Connecting-IP') ?? 'unknown';
    const key = `${ctx.req.url}:${ip}`;
    const now = Date.now();
    
    const entry = rateLimits.get(key);
    if (entry && entry.resetAt > now) {
      if (entry.count >= options.maxRequests) {
        return new Response(JSON.stringify({ error: 'rate_limited' }), {
          status: 429,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      entry.count++;
    } else {
      rateLimits.set(key, { count: 1, resetAt: now + options.windowMs });
    }
    
    return handler(ctx);
  };
}
