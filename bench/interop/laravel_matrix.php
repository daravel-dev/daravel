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

if ($step === 'jsonapi') {
    $classes = <<<'PHP'
    class MatrixAuthor extends \Illuminate\Database\Eloquent\Model { protected $table = 'authors'; public $timestamps = false; }
    class MatrixComment extends \Illuminate\Database\Eloquent\Model {
        protected $table = 'comments'; public $timestamps = false;
        public function author() { return $this->belongsTo(MatrixAuthor::class, 'author_id'); }
    }
    class MatrixPost extends \Illuminate\Database\Eloquent\Model {
        protected $table = 'posts'; public $timestamps = false;
        public function author() { return $this->belongsTo(MatrixAuthor::class, 'author_id'); }
        public function comments() { return $this->hasMany(MatrixComment::class, 'post_id'); }
    }
    class MatrixAuthorResource extends Illuminate\Http\Resources\JsonApi\JsonApiResource {
        public function toType($request) { return 'authors'; }
        public function toAttributes($request) { return ['name' => $this->resource->name]; }
    }
    class MatrixCommentResource extends Illuminate\Http\Resources\JsonApi\JsonApiResource {
        public function toType($request) { return 'comments'; }
        public function toAttributes($request) { return ['body' => $this->resource->body, 'stars' => $this->resource->stars]; }
        public function toRelationships($request) { return ['author' => MatrixAuthorResource::class]; }
    }
    class MatrixPostResource extends Illuminate\Http\Resources\JsonApi\JsonApiResource {
        public function toType($request) { return 'posts'; }
        public function toAttributes($request) { return ['title' => $this->resource->title, 'body' => $this->resource->body]; }
        public function toRelationships($request) { return ['author' => MatrixAuthorResource::class, 'comments' => MatrixCommentResource::class]; }
        public function toLinks($request) { return ['self' => '/posts/'.$this->resource->id]; }
        public function toMeta($request) { return ['views' => 3]; }
    }
    PHP;
    eval($classes);
    $author = fn (int $id, string $name) => (new MatrixAuthor)->forceFill(['id' => $id, 'name' => $name]);
    $comment = fn (int $id, string $body, $by) => (new MatrixComment)
        ->forceFill(['id' => $id, 'body' => $body, 'stars' => $id * 2])->setRelation('author', $by);
    $post = function (int $id, $by, array $comments) {
        return (new MatrixPost)->forceFill(['id' => $id, 'title' => "T$id", 'body' => "B$id"])
            ->setRelation('author', $by)
            ->setRelation('comments', new Illuminate\Database\Eloquent\Collection($comments));
    };
    $ana = $author(1, 'Ana');
    $budi = $author(2, 'Budi');
    $one = $post(1, $ana, [$comment(1, 'c1', $budi), $comment(2, 'c2', $ana)]);
    $two = $post(2, $ana, []);
    $three = $post(3, null, []);
    $app->booted(function () use ($one, $two, $three) {
        Route::get('/jsonapi/post', fn () => new MatrixPostResource($one));
        Route::get('/jsonapi/empty', fn () => new MatrixPostResource($two));
        Route::get('/jsonapi/none', fn () => new MatrixPostResource($three));
        Route::get('/jsonapi/posts', fn () => MatrixPostResource::collection(collect([$one, $two])));
        Route::get('/jsonapi/page', fn () => MatrixPostResource::collection(
            new LengthAwarePaginator([$one, $two], 30, 2, 2, ['path' => 'http://localhost/posts'])
        ));
    });
    $kernel = $app->make(Illuminate\Contracts\Http\Kernel::class);
    $result = [];
    foreach ([
        '/jsonapi/post',
        '/jsonapi/post?include=author',
        '/jsonapi/post?include=comments',
        '/jsonapi/post?include=comments.author',
        '/jsonapi/post?include=author,comments.author',
        '/jsonapi/post?fields[posts]=title',
        '/jsonapi/post?fields[posts]=',
        '/jsonapi/post?include=comments&fields[comments]=body',
        '/jsonapi/post?include=nothing',
        '/jsonapi/empty?include=comments',
        '/jsonapi/none?include=author',
        '/jsonapi/posts?include=author',
        '/jsonapi/posts?include=comments.author',
        '/jsonapi/page?include=author',    ] as $uri) {
        $response = $kernel->handle(Request::create($uri, 'GET', [], [], [], ['HTTP_ACCEPT' => 'application/vnd.api+json']));
        // Without \/, and with the keys in the order Laravel wrote them.
        $result[] = [
            'uri' => $uri,
            'status' => $response->getStatusCode(),
            'type' => $response->headers->get('content-type'),
            'body' => json_encode(json_decode($response->getContent()), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
        ];
    }
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

    case 'errors-write':
        $store = $session();
        $store->start();
        $store->flash('errors', (new Illuminate\Support\ViewErrorBag)->put(
            'default',
            new Illuminate\Support\MessageBag(['title' => ['Laravel says.']]),
        ));
        $store->save();
        echo json_encode([
            'id' => $store->getId(),
            'cookie' => app('encrypter')->encrypt(
                CookieValuePrefix::create($cookie, app('encrypter')->getKey()).$store->getId(),
                false,
            ),
        ]), "\n";
        break;

    case 'errors-read':
        $store = $session();
        $store->setId($argv[2]);
        $store->start();
        $errors = $store->get('errors');
        // What ShareErrorsFromSession and Inertia call.
        echo json_encode([
            'bag' => $errors instanceof Illuminate\Support\ViewErrorBag,
            'any' => $errors->any(),
            'first' => $errors->getBag('default')->first('title'),
            'bags' => array_keys($errors->getBags()),
        ]), "\n";
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
