<?php

// The endpoints of bench/lib/bench_app.dart (BLUEPRINT_V2 §10.2 scenarios 2-6).

use App\Models\Post;
use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;

Route::get('/users/{id}', fn (int $id) => User::findOrFail($id));

Route::post('/users', function (Request $request) {
    $data = $request->validate([
        'name' => 'required|string|max:255',
        'email' => 'required|email|max:255',
    ]);

    return DB::transaction(fn () => User::create([...$data, 'password' => 'x']));
});

Route::get('/posts', fn () => Post::with(['author', 'comments'])->orderBy('id')->limit(20)->get());

Route::get('/throttled', fn () => response('ok', 200, ['Content-Type' => 'text/plain; charset=utf-8']))
    ->middleware('throttle:bench');

Route::post('/login', function () {
    // As Daravel's Auth.retrieveByCredentials: find the user, verify bcrypt.
    $credentials = ['email' => 'user1@bench.test', 'password' => 'bench-password'];
    $provider = Auth::getProvider();
    $user = $provider->retrieveByCredentials($credentials);

    return $user && $provider->validateCredentials($user, $credentials)
        ? response()->json(['ok' => true])
        : response()->json(['message' => 'Invalid credentials.'], 422);
});
