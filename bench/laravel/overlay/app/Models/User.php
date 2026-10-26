<?php

namespace App\Models;

use Illuminate\Foundation\Auth\User as Authenticatable;

// No 'password' => 'hashed' cast: the benchmark inserts 'x' as Daravel does,
// so scenario 3 measures validation and the insert, not bcrypt.
class User extends Authenticatable
{
    protected $fillable = ['name', 'email', 'password'];

    protected $hidden = ['password'];
}
