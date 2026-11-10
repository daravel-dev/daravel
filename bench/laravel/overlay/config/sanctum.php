<?php

// Sanctum's published defaults, plus `last_used_at` (read by
// SanctumServiceProvider as config('sanctum.last_used_at', true)): Sanctum
// writes last_used_at on every authenticated request unless it is false.
// SANCTUM_LAST_USED_AT=false matches Daravel, which writes it at most once a
// minute per token.
return [
    'stateful' => [],
    'guard' => ['web'],
    'expiration' => null,
    'token_prefix' => '',
    'last_used_at' => env('SANCTUM_LAST_USED_AT', true),
    'middleware' => [],
];
