import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Account extends Model {
  static final ModelDefinition<Account> definition = ModelDefinition<Account>(
    table: 'accounts',
    factory: Account.new,
  );

  @override
  ModelDefinition<Account> get modelDefinition => Account.definition;

  static const cols = (
    id: ModelColumn<Account, int>('id'),
    email: ModelColumn<Account, String>('email'),
  );
}

/// Typed rule arguments (W9.4b): `Field<T>` names an input field once;
/// `Rules.of(definition)` gives `unique` and `exists` on a model's typed
/// columns, the same rules as the strings.
void main() {
  late DatabaseManager db;
  late Container container;

  const email = Field<String>('email');
  const password = Field<String>('password');
  const confirmation = Field<String>('password_confirmation');

  setUp(() async {
    db = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
        },
      ),
    );
    await db.statement(
      'CREATE TABLE accounts ("id" INTEGER PRIMARY KEY AUTOINCREMENT, '
      '"email" TEXT)',
    );
    await db.table('accounts').insert({'email': 'taken@example.com'});
    container = Container()..instance<DatabaseManager>(db);
  });

  tearDown(() => db.closeAll());

  Future<Map<String, List<String>>> errors(
    Map<String, Object?> data,
    Map<String, Object> rules, {
    Map<String, String> messages = const {},
  }) => Validator(data, rules, messages: messages, container: container).run();

  test('Rules.of(...).unique and exists read the model table', () async {
    final unique = {
      email: [Rules.of(Account.definition).unique(Account.cols.email)],
    };
    expect(await errors({'email': 'new@example.com'}, unique), isEmpty);
    expect(await errors({'email': 'taken@example.com'}, unique), {
      'email': ['The email has already been taken.'],
    });
    // The same as the string form.
    expect(
      await errors(
        {'email': 'taken@example.com'},
        {'email': 'unique:accounts,email'},
      ),
      await errors({'email': 'taken@example.com'}, unique),
    );
    final exists = {
      'id': [Rules.of(Account.definition).exists(Account.cols.id)],
    };
    expect(await errors({'id': 1}, exists), isEmpty);
    expect(await errors({'id': 9}, exists), {
      'id': ['The selected id is invalid.'],
    });
  });

  test(
    'unique ignores a row by the primary key, or by a typed column',
    () async {
      final rule = Rules.of(Account.definition)
          .unique(Account.cols.email, ignore: 1);
      expect(
        await errors(
          {'email': 'taken@example.com'},
          {
            email: [rule],
          },
        ),
        isEmpty,
      );
      expect(rule.idColumn, 'id');
      expect(
        Rules.of(Account.definition)
            .unique(Account.cols.email, idColumn: Account.cols.email)
            .idColumn,
        'email',
      );
    },
  );

  test('a Field is the key, an argument and a message key', () async {
    final result = await errors(
      {'email': 'x', 'password': 'a', 'password_confirmation': 'b'},
      {
        email: [Rules.required(), Rules.email()],
        confirmation: [Rules.same(password)],
      },
      messages: {email.on(Rules.email()): 'Use a real address.'},
    );
    expect(result, {
      'email': ['Use a real address.'],
      'password_confirmation': [
        'The password confirmation field must match password.',
      ],
    });
    expect(email.on(Rules.required()), 'email.required');
  });
}
