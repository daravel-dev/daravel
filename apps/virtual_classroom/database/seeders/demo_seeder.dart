import 'package:daravel/daravel.dart';
import 'package:daravel_permission/daravel_permission.dart';
import 'package:virtual_classroom/app/models/classroom.dart';
import 'package:virtual_classroom/app/models/meeting.dart';
import 'package:virtual_classroom/app/models/user.dart';

/// A teacher, a classroom of three students and a meeting starting in ten
/// minutes. Every user logs in with "password".
final class DemoSeeder extends Seeder {
  const DemoSeeder();

  @override
  Future<void> run() async {
    await Role.findOrCreate('teacher');
    await Role.findOrCreate('student');
    final password = await Hash.make('password');
    final teacher = await User.query().create({
      'name': 'Teacher',
      'email': 'teacher@example.com',
      'password': password,
    });
    await teacher.assignRole('teacher');
    final classroom = await Classroom.query().create({
      'name': 'Mathematics 7A',
      'teacher_id': teacher.id,
    });
    for (var i = 1; i <= 3; i++) {
      final student = await User.query().create({
        'name': 'Student $i',
        'email': 'student$i@example.com',
        'password': password,
      });
      await student.assignRole('student');
      await classroom.attach('students', student);
    }
    final uuid = Str.uuid();
    final starts = Clock.now().add(const Duration(minutes: 10));
    await Meeting.query().create({
      'uuid': uuid,
      'classroom_id': classroom.id,
      'created_by': teacher.id,
      'name': 'Fractions',
      'starts_at': starts,
      'ends_at': starts.add(const Duration(minutes: 45)),
      'room_name': 'meeting-$uuid',
      'status': 'published',
    });
  }
}
