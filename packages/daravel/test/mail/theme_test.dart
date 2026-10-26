import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class OrderShipped extends Mailable {
  OrderShipped(this.number);
  final String number;

  @override
  Envelope envelope() => const Envelope(subject: 'Shipped');

  @override
  MailContent content() => MailContent(
    markdown:
        '# Order ${escapeHtml(number)} shipped\n\n'
        'It is on its way.\n\n'
        '${mailButton('Track <it>', 'https://shop.test/track?a=1&b=2', color: 'success')}\n\n'
        '${mailPanel('Delivery **tomorrow**.')}\n\n'
        'Thanks,<br>\nShop',
  );
}

final class Reset extends Notification {
  const Reset();
  @override
  List<String> via(Object notifiable) => ['mail'];
  @override
  NotificationMail toMail(Object notifiable) => NotificationMail()
      .error()
      .line('Someone asked to reset <your> password.')
      .action('Reset password', 'https://shop.test/reset?t=1&u=2');
}

void main() {
  const theme = MailTheme(appName: 'Shop', appUrl: 'https://shop.test');

  test('components render as Laravel\'s, with escaped content', () {
    final html = theme.render(
      '${mailButton('Pay <now>', 'https://x.test/?a=1&b="2"', color: 'error')}\n\n'
      '<x-mail::panel>\n**Code** 4821\n</x-mail::panel>',
    );
    expect(html, contains('class="button button-error"'));
    expect(html, contains('background-color: #dc2626'));
    expect(html, contains('Pay &lt;now&gt;</a>'));
    expect(html, contains('href="https://x.test/?a=1&amp;b=&quot;2&quot;"'));
    expect(html, contains('class="panel"'));
    expect(html, contains('<strong>Code</strong>'));
    expect(html, isNot(contains('<x-mail')));
  });

  test('markdown elements get the theme\'s inline styles', () {
    final html = theme.render('# Hi\n\nText with [a link](https://x.test).');
    expect(RegExp('<h1[^>]* style="').hasMatch(html), isTrue);
    expect(html, contains('color: #18181b; font-size: 18px;'));
    expect(html, contains('<p style="'));
    expect(html, contains('color: #52525b'));
    expect(html, contains('<a href="https://x.test" style="'));
  });

  test('layout: header, body, subcopy and footer', () {
    final html = theme.layout('<p>Body</p>', subcopy: 'Small print');
    expect(html, startsWith('<!DOCTYPE html'));
    expect(html, contains('href="https://shop.test"'));
    expect(html, contains('>Shop</a>'));
    expect(html, contains('class="inner-body"'));
    expect(html, contains('class="subcopy"'));
    expect(html, contains('Small print'));
    expect(
      html,
      contains('© ${DateTime.now().year} Shop. All rights reserved.'),
    );
    // The footer's own color, not the body text color.
    expect(
      RegExp('<p style="[^"]*color: #a1a1aa[^"]*">©').hasMatch(html),
      isTrue,
    );
  });

  test('markdownToText turns buttons and links into text: url', () {
    expect(
      markdownToText(
        '# Hi\n\n${mailButton('Track', 'https://x.test/?a=1&b=2')}\n\n'
        'See [the docs](https://docs.test).<br>\nBye',
      ),
      '# Hi\n\nTrack: https://x.test/?a=1&b=2\n\n'
      'See the docs: https://docs.test.\nBye',
    );
  });

  group('in an application', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {
            'APP_ENV': 'testing',
            'APP_NAME': 'Shop',
            'APP_URL': 'https://shop.test',
            'DB_DATABASE': ':memory:',
          })
          .withMailTheme((theme) => theme.copyWith(primary: '#4f46e5'))
          .create();
      await app.boot();
    });

    tearDown(() => app.shutdown());

    test('a markdown mailable is sent as themed HTML and text', () async {
      final fake = Mail.fake();
      addTearDown(Mail.restore);
      await Mail.to('teo@shop.test').send(OrderShipped('A-7'));
      final message = fake.messages.single.message;
      expect(message.html, contains('>Shop</a>'));
      expect(message.html, contains('Order A-7 shipped'));
      expect(message.html, contains('class="button button-success"'));
      // withMailTheme changed the primary color: the panel's border.
      expect(message.html, contains('border-left: #4f46e5 solid 4px'));
      expect(
        message.text,
        contains('Track <it>: https://shop.test/track?a=1&b=2'),
      );
      expect(message.text, isNot(contains('<x-mail')));
    });

    test('notification mail follows Laravel\'s template', () async {
      final fake = Mail.fake();
      addTearDown(Mail.restore);
      await Notifications.route('mail', 'teo@shop.test').notify(const Reset());
      final html = fake.messages.single.message.html!;
      expect(html, contains('>Whoops!</h1>'));
      // User text is escaped, as Blade's {{ }} does.
      expect(html, contains('reset &lt;your&gt; password'));
      expect(html, contains('class="button button-error"'));
      expect(html, contains('Regards,<br>\nShop'));
      expect(
        html,
        contains(
          'having trouble clicking the &quot;Reset password&quot; button',
        ),
      );
      expect(html, contains('class="subcopy"'));
    });
  });
}
