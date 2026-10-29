import { test, expect } from '@playwright/test';

// Unique per run: the database outlives a run when the server is reused.
const user = {
  name: 'E2E Tester',
  email: `e2e_${Date.now()}@example.test`,
  password: 'Secret-pass-123',
  password_confirmation: 'Secret-pass-123',
};

test.describe.serial('token authentication', () => {
  let token = '';

  test('register returns the user and a token', async ({ request }) => {
    const res = await request.post('/api/auth/register', { data: user });
    expect(res.status()).toBe(201);
    const body = await res.json();
    expect(body.user.email).toBe(user.email);
    expect(body.token_type).toBe('Bearer');
    token = body.token;
  });

  test('the token opens /api/auth/me, until logout', async ({ request }) => {
    const auth = { Authorization: `Bearer ${token}` };
    const me = await request.get('/api/auth/me', { headers: auth });
    expect(me.status()).toBe(200);
    expect((await me.json()).data.email).toBe(user.email);

    const logout = await request.post('/api/auth/logout', { headers: auth });
    expect(logout.status()).toBe(204);

    const after = await request.get('/api/auth/me', { headers: auth });
    expect(after.status()).toBe(401);
  });

  test('login with the password returns a new token', async ({ request }) => {
    const res = await request.post('/api/auth/login', {
      data: { email: user.email, password: user.password },
    });
    expect(res.status()).toBe(200);
    expect((await res.json()).token).toBeTruthy();
  });
});

test("an invalid form answers Laravel's 422 body", async ({ request }) => {
  const res = await request.post('/api/auth/register', { data: {} });
  expect(res.status()).toBe(422);
  const body = await res.json();
  expect(body.message).toBeTruthy();
  expect(Object.keys(body.errors)).toEqual(
    expect.arrayContaining(['name', 'email', 'password']),
  );
});

test('login is rate limited per email', async ({ request }) => {
  const data = {
    email: `nobody_${Date.now()}@example.test`,
    password: 'wrong-password',
  };
  const statuses: number[] = [];
  for (let i = 0; i < 6; i++) {
    statuses.push((await request.post('/api/auth/login', { data })).status());
  }
  expect(statuses.slice(0, 5)).toEqual([422, 422, 422, 422, 422]);
  expect(statuses[5]).toBe(429);
});
