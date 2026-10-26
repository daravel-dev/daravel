<?php

namespace App\Providers;

use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        // Scenario 5: a limit high enough never to trigger, as in Daravel.
        RateLimiter::for('bench', fn (Request $request) => Limit::perMinute(1 << 30)->by($request->ip()));
    }
}
