<?php

// The Laravel side of bench/interop/laravel_matrix.sh: one step per run,
// against the installed framework. Uses only what every version from 8 to
// 13 has.

use Illuminate\Cookie\CookieValuePrefix;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cookie;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\Schema;

require '/app/vendor/autoload.php';
$app = require '/app/bootstrap/app.php';

class Exam extends Model
{
    public $timestamps = false;

    protected $casts = ['price' => 'decimal:2', 'ratio' => 'decimal:3'];
}

$step = $argv[1];
$cookie = 'interop_session';
$login = 'login_web_'.sha1(Illuminate\Auth\SessionGuard::class);

if ($step === 'wire') {
    $app->booted(function () {
        Route::post('/wire/validate', function (Request $request) {
            $request->validate([
                'email' => 'required|email',
                'name' => 'required|min:3',
                'age' => 'integer',
            ]);

            return ['ok' => true];
        });
        Route::post('/wire/terms', function (Request $request) {
            $request->validate([
                'tos' => 'accepted',
                'paid_tos' => 'accepted_if:plan,paid,gold',
                'ads' => 'declined',
                'calls' => 'declined_if:plan,paid',
            ]);

            return ['ok' => true];
        });
        Route::get('/wire/model', function () {
            $exam = (new Exam)->forceFill(['id' => 1, 'price' => '12.5', 'ratio' => '0.1255']);
            $exam->setRelation('tipeUjian', (new Exam)->forceFill(['id' => 2, 'price' => '0.125', 'ratio' => 3]));
            $exam->setRelation('jenisSoal', null);

            return response()->json($exam);
        });
        Route::get('/wire/paginator', fn () => response()->json(
            new LengthAwarePaginator([1, 2], 30, 15, 2, ['path' => 'http://localhost/items'])
        ));
        Route::bind('user', fn () => abort(404));
        Route::get('/wire/bound/{user}', fn () => 'x')
            ->middleware(['auth', Illuminate\Routing\Middleware\SubstituteBindings::class]);
    });
    $kernel = $app->make(Illuminate\Contracts\Http\Kernel::class);
    $server = ['HTTP_ACCEPT' => 'application/json', 'CONTENT_TYPE' => 'application/json'];
    $result = [];
    foreach ([
        ['POST', '/wire/validate', json_encode(['email' => 'x', 'age' => 'a'])],
        ['GET', '/wire/nope', null],
        ['GET', '/wire/validate', null],
        ['POST', '/wire/terms', json_encode(['plan' => 'gold', 'tos' => 'no', 'ads' => 'yes'])],
        ['GET', '/wire/model', null],
        ['GET', '/wire/paginator', null],
        ['GET', '/wire/bound/7', null],
    ] as [$method, $uri, $body]) {
        $response = $kernel->handle(Request::create($uri, $method, [], [], [], $server, $body));
        $result[] = ['status' => $response->getStatusCode(), 'body' => $response->getContent()];
    }
    // Without \/ here, as dart:convert writes the wrapper around the bodies.
    echo json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";
    exit(0);
}

$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
config([
    'session.driver' => 'database',
    'session.cookie' => $cookie,
    'session.encrypt' => getenv('SESSION_ENCRYPT') === 'true',
    'session.serialization' => getenv('SESSION_SERIALIZATION') ?: 'php',
]);
$session = fn () => app('session')->driver();

switch ($step) {
    case 'migrate':
        // The user of the login key: the session handler loads it.
        Schema::create('users', function ($table) {
            $table->id();
            $table->string('name');
            $table->string('email')->unique();
            $table->string('password');
            $table->rememberToken();
            $table->timestamps();
        });
        DB::table('users')->insert(['id' => 7, 'name' => 'Ana', 'email' => 'ana@example.com', 'password' => Hash::make('secret')]);
        // laravel/laravel's sessions migration.
        Schema::create('sessions', function ($table) {
            $table->string('id')->primary();
            $table->foreignId('user_id')->nullable()->index();
            $table->string('ip_address', 45)->nullable();
            $table->text('user_agent')->nullable();
            $table->longText('payload');
            $table->integer('last_activity')->index();
        });
        echo app()->version(), ' PHP ', PHP_VERSION, "\n";
        break;

    case 'write':
        $store = $session();
        $store->start();
        $store->put('name', 'Ana é');
        $store->put($login, 7);
        $store->flash('status', 'saved');
        $store->save();
        echo json_encode([
            'id' => $store->getId(),
            'cookie' => app('encrypter')->encrypt(
                CookieValuePrefix::create($cookie, app('encrypter')->getKey()).$store->getId(),
                false,
            ),
        ]), "\n";
        break;

    case 'read':
        $store = $session();
        $store->setId($argv[2]);
        $store->start();
        $guard = Auth::guard('web');
        $user = $guard->user();
        echo json_encode([
            'name' => $store->get('name'),
            'login' => $store->get($login),
            'daravel' => $store->get('daravel'),
            'status' => $store->get('status'),
            'token' => strlen((string) $store->token()),
            'user' => $user?->id,
            // AuthenticateSession's check, on the versions that have it.
            'password_hash' => $user && method_exists($guard, 'hashPasswordForCookie')
                ? hash_equals($guard->hashPasswordForCookie($user->password), (string) $store->get('password_hash_web'))
                : null,
        ], JSON_UNESCAPED_UNICODE), "\n";
        break;

    case 'remember-write':
        $session()->start();
        $guard = Auth::guard('web');
        $guard->login(App\Models\User::find(7), true);
        $name = $guard->getRecallerName();
        foreach (Cookie::getQueuedCookies() as $queued) {
            if ($queued->getName() === $name) {
                echo json_encode(['name' => $name, 'cookie' => app('encrypter')->encrypt(
                    CookieValuePrefix::create($name, app('encrypter')->getKey()).$queued->getValue(),
                    false,
                )]), "\n";
            }
        }
        break;

    case 'recall':
        $session()->start();
        $clear = CookieValuePrefix::remove(app('encrypter')->decrypt($argv[3], false));
        $guard = Auth::guard('web');
        $guard->setRequest(Request::create('/', 'GET', [], [$argv[2] => $clear]));
        echo json_encode(['user' => $guard->user()?->id]), "\n";
        break;

    case 'format':
        $payload = base64_decode(DB::table('sessions')->where('id', $argv[2])->value('payload'));
        echo $payload[0] === '{' ? 'json' : ($payload[1] === ':' ? 'php' : 'encrypted'), "\n";
        break;

    case 'crypt':
        echo json_encode([
            'encrypt' => Crypt::encrypt('fröm laravel'),
            'string' => Crypt::encryptString('fröm laravel'),
            'hash' => Hash::make('secret'),
        ]), "\n";
        break;

    case 'decrypt':
        echo json_encode([
            'encrypt' => Crypt::decrypt($argv[2]),
            'string' => Crypt::decryptString($argv[3]),
            'hash' => Hash::check('secret', $argv[4]),
        ], JSON_UNESCAPED_UNICODE), "\n";
        break;

    default:
        throw new InvalidArgumentException($step);
}
