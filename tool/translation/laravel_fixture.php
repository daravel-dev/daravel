<?php
// Produces packages/daravel/test/translation/laravel_translation_fixture.json
// from Laravel 12's Translator and MessageSelector.
require '/app/vendor/autoload.php';

use Illuminate\Translation\ArrayLoader;
use Illuminate\Translation\MessageSelector;
use Illuminate\Translation\Translator;

$selector = new MessageSelector();
$source = file_get_contents('/app/vendor/laravel/framework/src/Illuminate/Translation/MessageSelector.php');
preg_match_all("/case '([^']+)':/", $source, $m);
$locales = array_values(array_unique($m[1]));
$numbers = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 19, 20, 21, 22, 25, 99, 100, 101, 102, 103, 111, 112, 1000, -1, -21, 1.5, 0.5];
$plural = [];
foreach ($locales as $locale) {
    $plural[$locale] = array_map(fn ($n) => $selector->getPluralIndex($locale, $n), $numbers);
}

$lines = [
    '{0} none|{1} one|[2,*] many',
    'one|many',
    'apple|apples',
    '[0,5] few|[6,*] lots',
    '[*,1] at most one|[2,*] more',
    '{1} :count minute left|[2,*] :count minutes left',
    'only one form',
    ' spaced | forms ',
    '{0}zero|one|many',
    'satu|dua|tiga|empat',
];
$choose = [];
foreach ($lines as $line) {
    foreach (['en', 'id', 'ru', 'ar'] as $locale) {
        foreach ([0, 1, 2, 3, 5, 6, 11, 21, 100, 1.5] as $n) {
            $choose[] = [$line, $n, $locale, $selector->choose($line, $n, $locale)];
        }
    }
}

$translator = new Translator(new ArrayLoader(), 'en');
$translator->setFallback('en');
$translator->addLines([
    'messages.welcome' => 'Welcome, :name!',
    'messages.shout' => ':NAME and :Name and :name',
    'messages.overlap' => ':name / :named / :name_full',
    'messages.only_en' => 'English only',
    'messages.minutes' => '{1} :count minute left|[2,*] :count minutes left',
    'messages.apples' => 'apple|apples',
], 'en');
$translator->addLines([
    'messages.welcome' => 'Selamat datang, :name!',
    'messages.minutes' => ':count menit tersisa',
], 'id');

$replace = [
    ['Welcome, :name!', ['name' => 'teo']],
    [':NAME and :Name and :name', ['name' => 'teo prayoga']],
    [':name / :named / :name_full', ['name' => 'a', 'named' => 'b', 'name_full' => 'c']],
    ['Hello :name', ['name' => 'value with :count inside', 'count' => 3]],
    ['No placeholders', ['name' => 'x']],
    [':a:b :ab', ['a' => '1', 'b' => '2', 'ab' => '3']],
    ['Price: :amount', ['amount' => 12.5]],
    ['Empty :name.', ['name' => null]],
];
$replacements = [];
foreach ($replace as [$line, $values]) {
    $translator->addLines(['tmp.line' => $line], 'en');
    $replacements[] = [$line, $values, $translator->get('tmp.line', $values, 'en')];
}

$get = [];
foreach ([
    ['messages.welcome', ['name' => 'Teo'], 'en'],
    ['messages.welcome', ['name' => 'Teo'], 'id'],
    ['messages.only_en', [], 'id'],
    ['messages.missing', ['name' => 'x'], 'id'],
    ['messages.missing :name', ['name' => 'x'], 'en'],
] as [$key, $values, $locale]) {
    $get[] = [$key, $values, $locale, $translator->get($key, $values, $locale)];
}
$choice = [];
foreach ([
    ['messages.minutes', 1, 'en'],
    ['messages.minutes', 5, 'en'],
    ['messages.minutes', 5, 'id'],
    ['messages.apples', 1, 'id'],
    ['messages.apples', 2, 'id'],
    ['messages.apples', 0, 'en'],
] as [$key, $n, $locale]) {
    $choice[] = [$key, $n, $locale, $translator->choice($key, $n, [], $locale)];
}

echo json_encode([
    'source' => 'Laravel ' . \Illuminate\Foundation\Application::VERSION,
    'numbers' => $numbers,
    'pluralIndex' => $plural,
    'choose' => $choose,
    'replacements' => $replacements,
    'get' => $get,
    'choice' => $choice,
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRESERVE_ZERO_FRACTION);
