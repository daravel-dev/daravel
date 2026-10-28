// Model registry: the models `model_type` / `subject_type` columns name.
import 'package:daravel/daravel.dart';
import 'package:virtual_classroom/app/models/classroom.dart';
import 'package:virtual_classroom/app/models/meeting.dart';
import 'package:virtual_classroom/app/models/user.dart';

final List<ModelDefinition<Model>> models = <ModelDefinition<Model>>[
  // <dartisan:entries>
  User.definition,
  Classroom.definition,
  Meeting.definition,
  // </dartisan:entries>
];
