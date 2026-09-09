export function withCache(
  handler: (ctx: any) => Promise<Response>,
  options: { maxAge: number; staleWhileRevalidate?: number }
) {
  return async (ctx: any): Promise<Response> => {
    const res = await handler(ctx);
    const headers = new Headers(res.headers);
    headers.set('Cache-Control', 
      `public, max-age=${options.maxAge}, stale-while-revalidate=${options.staleWhileRevalidate ?? 60}`
    );
    return new Response(res.body, { ...res, headers });
  };
}
