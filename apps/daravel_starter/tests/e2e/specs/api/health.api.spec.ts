import { test, expect } from '@playwright/test';

test('the health check answers', async ({ request }) => {
  expect((await request.get('/up')).status()).toBe(200);
});

test('an API route answers JSON', async ({ request }) => {
  const res = await request.get('/api/ping');
  expect(res.status()).toBe(200);
  expect(await res.json()).toMatchObject({ message: 'pong' });
});

test("an unknown route answers Laravel's 404 body", async ({ request }) => {
  const res = await request.get('/api/no-such-route');
  expect(res.status()).toBe(404);
  expect(await res.json()).toHaveProperty('message');
});
