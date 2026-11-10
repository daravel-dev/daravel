<?php

namespace App\Models;

use Illuminate\Foundation\Auth\User as Authenticatable;
use Laravel\Sanctum\HasApiTokens;

// No 'password' => 'hashed' cast: the benchmark inserts 'x' as Daravel does,
// so scenario 3 measures validation and the insert, not bcrypt.
// HasApiTokens: scenario 14 authenticates with a Sanctum token.
class User extends Authenticatable
{
    use HasApiTokens;

    protected $fillable = ['name', 'email', 'password'];

    protected $hidden = ['password'];
}
