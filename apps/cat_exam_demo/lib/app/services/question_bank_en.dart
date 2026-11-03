import 'question_bank.dart';

/// The English question bank: the same ids, answer keys and option scores as
/// [QuestionBank.indonesian], so a session scores the same in either language.
///
/// Question 5 tests standard official writing; it is adapted to English
/// rather than translated, as the Indonesian one tests Indonesian spelling.
const List<QuestionData> englishQuestions = [
  // TWK (civic knowledge)
  QuestionData(
    id: 1,
    category: 'TWK',
    questionText:
        'In the digital transformation of local government, the third principle of '
        'Pancasila, "the unity of Indonesia", is best put into practice by...',
    correctOption: 'C',
    options: [
      OptionData(
        id: 'A',
        text: 'Limiting official communication to employees who come from the same region.',
        score: 0,
      ),
      OptionData(
        id: 'B',
        text: "Refusing national applications to keep the district's own technology independent.",
        score: 0,
      ),
      OptionData(
        id: 'C',
        text:
            'Integrating digital services across agencies so that every part of society '
            'can reach them without discrimination.',
        score: 5,
      ),
      OptionData(
        id: 'D',
        text: 'Creating an exclusive social media group for high-performing civil servants in the district.',
        score: 0,
      ),
      OptionData(
        id: 'E',
        text: 'Spending the regional IT budget first and assessing its effect on social unity later.',
        score: 0,
      ),
    ],
  ),
  QuestionData(
    id: 2,
    category: 'TWK',
    questionText:
        'Under Article 24C(1) of the 1945 Constitution, the Constitutional Court rules '
        'at the first and final instance, with final decisions, to...',
    correctOption: 'B',
    options: [
      OptionData(
        id: 'A',
        text: 'Review government regulations against statutes and settle regional election disputes.',
        score: 0,
      ),
      OptionData(
        id: 'B',
        text:
            'Review statutes against the 1945 Constitution and settle disputes over the powers '
            'of state institutions granted by the Constitution.',
        score: 5,
      ),
      OptionData(
        id: 'C',
        text: 'Advise the President on clemency and rehabilitation for those convicted of corruption.',
        score: 0,
      ),
      OptionData(
        id: 'D',
        text: 'Appoint Supreme Court justices and oversee the ethics of general courts in the regions.',
        score: 0,
      ),
      OptionData(
        id: 'E',
        text:
            'Enact district budget bills that are stuck in political deadlock.',
        score: 0,
      ),
    ],
  ),
  QuestionData(
    id: 3,
    category: 'TWK',
    questionText:
        'Under Law No. 23 of 2019 on National Resources for State Defence, one of the core '
        'values of defending the state that every civil servant must take on is...',
    correctOption: 'D',
    options: [
      OptionData(
        id: 'A',
        text: 'Being ready to carry a firearm in daily official duties.',
        score: 0,
      ),
      OptionData(
        id: 'B',
        text: 'Absolute obedience to the political instructions of the elected regional head.',
        score: 0,
      ),
      OptionData(
        id: 'C',
        text: 'Neglecting family matters for unplanned overtime assignments.',
        score: 0,
      ),
      OptionData(
        id: 'D',
        text: 'Loyalty to Pancasila as the state ideology and willingness to sacrifice for the nation and the state.',
        score: 5,
      ),
      OptionData(
        id: 'E',
        text: 'Refusing international aid in handling regional disasters.',
        score: 0,
      ),
    ],
  ),
  QuestionData(
    id: 4,
    category: 'TWK',
    questionText:
        'The principle of Bhinneka Tunggal Ika ("unity in diversity") in public services '
        'at a district office means that civil servants must...',
    correctOption: 'A',
    options: [
      OptionData(
        id: 'A',
        text:
            'Give equal, fair and professional service regardless of ethnicity, religion, '
            "race or a citizen's political background.",
        score: 5,
      ),
      OptionData(
        id: 'B',
        text: "Put first the applicants who share a family line with the head of the office.",
        score: 0,
      ),
      OptionData(
        id: 'C',
        text: "Make every applicant's local tradition fit one dominant culture at the office.",
        score: 0,
      ),
      OptionData(
        id: 'D',
        text: 'Stop public services whenever part of the community holds a customary celebration.',
        score: 0,
      ),
      OptionData(
        id: 'E',
        text:
            'Open separate service counters by mass organisation affiliation.',
        score: 0,
      ),
    ],
  ),
  QuestionData(
    id: 5,
    category: 'TWK',
    questionText: 'Which of the following official sentences is standard and effective written English?',
    correctOption: 'E',
    options: [
      OptionData(
        id: 'A',
        text: 'The local government is planning about the building of roads between the sub-districts.',
        score: 0,
      ),
      OptionData(
        id: 'B',
        text: 'All of the each candidates are expected to be present before the exam begins.',
        score: 0,
      ),
      OptionData(
        id: 'C',
        text: 'This decree is issued in order for to approve the standardisation of the district selection exam.',
        score: 0,
      ),
      OptionData(
        id: 'D',
        text: 'In the meeting discussed about raising the efficiency of regional staff spending.',
        score: 0,
      ),
      OptionData(
        id: 'E',
        text: 'The district government has standardised its computer-based exam system to make selection more accountable.',
        score: 5,
      ),
    ],
  ),

  // TIU (general intelligence)
  QuestionData(
    id: 6,
    category: 'TIU',
    questionText: 'VEHICLE : FUEL = HUMAN : ...',
    correctOption: 'B',
    options: [
      OptionData(id: 'A', text: 'WATER', score: 0),
      OptionData(id: 'B', text: 'FOOD', score: 5),
      OptionData(id: 'C', text: 'CLOTHING', score: 0),
      OptionData(id: 'D', text: 'ROAD', score: 0),
      OptionData(id: 'E', text: 'HOUSE', score: 0),
    ],
  ),
  QuestionData(
    id: 7,
    category: 'TIU',
    questionText:
        'Premise 1: Every civil servant with integrity refuses all forms of gratuity.\n'
        'Premise 2: Some officials in District X are civil servants with integrity.\n'
        'The valid conclusion is...',
    correctOption: 'C',
    options: [
      OptionData(
        id: 'A',
        text: 'Every official in District X refuses all forms of gratuity.',
        score: 0,
      ),
      OptionData(
        id: 'B',
        text: 'Some officials in District X accept official gratuities.',
        score: 0,
      ),
      OptionData(
        id: 'C',
        text: 'Some officials in District X refuse all forms of gratuity.',
        score: 5,
      ),
      OptionData(
        id: 'D',
        text: 'No official in District X refuses gratuities.',
        score: 0,
      ),
      OptionData(
        id: 'E',
        text: 'The officials in District X are not civil servants.',
        score: 0,
      ),
    ],
  ),
  QuestionData(
    id: 8,
    category: 'TIU',
    questionText:
        'What is the next number in the series?\n3, 7, 15, 31, 63, ...',
    correctOption: 'D',
    options: [
      OptionData(id: 'A', text: '95', score: 0),
      OptionData(id: 'B', text: '112', score: 0),
      OptionData(id: 'C', text: '124', score: 0),
      OptionData(id: 'D', text: '127', score: 5),
      OptionData(id: 'E', text: '135', score: 0),
    ],
  ),
  QuestionData(
    id: 9,
    category: 'TIU',
    questionText:
        'A CAT team verifies the files of 1,200 candidates in 4 hours with 6 servers. '
        'With 10 servers of the same specification, how long does it take to verify '
        'the files of 3,000 candidates?',
    correctOption: 'A',
    options: [
      OptionData(id: 'A', text: '6 hours', score: 5),
      OptionData(id: 'B', text: '5 hours', score: 0),
      OptionData(id: 'C', text: '7.5 hours', score: 0),
      OptionData(id: 'D', text: '8 hours', score: 0),
      OptionData(id: 'E', text: '4.5 hours', score: 0),
    ],
  ),
  QuestionData(
    id: 10,
    category: 'TIU',
    questionText:
        'Five department heads (A, B, C, D, E) present their results one after another. '
        'B presents right before C. D presents after A but before B. E presents first. '
        'Who presents third?',
    correctOption: 'B',
    options: [
      OptionData(id: 'A', text: 'A', score: 0),
      OptionData(id: 'B', text: 'D', score: 5),
      OptionData(id: 'C', text: 'B', score: 0),
      OptionData(id: 'D', text: 'C', score: 0),
      OptionData(id: 'E', text: 'E', score: 0),
    ],
  ),

  // TKP (personal characteristics), scored 1 to 5
  QuestionData(
    id: 11,
    category: 'TKP',
    questionText:
        'An elderly citizen comes to the service counter where you work and is confused '
        'by the self-service kiosk that issues queue numbers. You...',
    options: [
      OptionData(
        id: 'A',
        text:
            'Go to them kindly, guide them patiently through the screen, and explain the next '
            'steps until they feel at ease.',
        score: 5,
      ),
      OptionData(
        id: 'B',
        text: 'Ask the security guard to help them, because your own counter has a queue.',
        score: 3,
      ),
      OptionData(
        id: 'C',
        text: 'Tell them to wait for a relative or companion who knows smartphones better.',
        score: 2,
      ),
      OptionData(
        id: 'D',
        text: 'Greet them from behind the counter and guide them over the loudspeaker so others hear too.',
        score: 4,
      ),
      OptionData(
        id: 'E',
        text: 'Let them try alone first, so they learn to use modern public facilities.',
        score: 1,
      ),
    ],
  ),
  QuestionData(
    id: 12,
    category: 'TKP',
    questionText:
        "A technical problem in syncing data between your office's divisions may delay "
        'tomorrow\'s accountability report to the province. You...',
    options: [
      OptionData(
        id: 'A',
        text: 'Blame the division that runs the data server for not anticipating the file format problem.',
        score: 1,
      ),
      OptionData(
        id: 'B',
        text:
            'Call a quick meeting with both technical teams, find the root cause, and work '
            'overtime together to finish the sync.',
        score: 5,
      ),
      OptionData(
        id: 'C',
        text: 'Write the province an explanation of the problem so the office gets an extension.',
        score: 3,
      ),
      OptionData(
        id: 'D',
        text: "Work only on your own division's data and leave the other division's data to your superior.",
        score: 2,
      ),
      OptionData(
        id: 'E',
        text: 'Offer colleagues in the other division help with converting formats by hand if they are overwhelmed.',
        score: 4,
      ),
    ],
  ),
  QuestionData(
    id: 13,
    category: 'TKP',
    questionText:
        'The district has just launched an integrated digital platform to make selection '
        'more transparent and services faster. Some senior colleagues are reluctant to adapt '
        'and want to keep working by hand. You...',
    options: [
      OptionData(
        id: 'A',
        text:
            'Talk it over with them informally, show how the new system saves time, and sit '
            'with them while they enter data.',
        score: 5,
      ),
      OptionData(
        id: 'B',
        text: "Report their reluctance to the regional personnel agency so they receive a disciplinary warning.",
        score: 2,
      ),
      OptionData(
        id: 'C',
        text: "Take over all of their digital tasks yourself so the office's work still gets done fast.",
        score: 3,
      ),
      OptionData(
        id: 'D',
        text: "Make a short illustrated guide and share it in the office chat group to read when they have time.",
        score: 4,
      ),
      OptionData(
        id: 'E',
        text: 'Leave it, since seniority deserves respect, and wait until they decide to learn on their own.',
        score: 1,
      ),
    ],
  ),
  QuestionData(
    id: 14,
    category: 'TKP',
    questionText:
        "As you get ready to leave on time for your child's birthday party, the head of the "
        'office gives you an urgent task: verifying exam documents that must be finished '
        'tonight. What do you do?',
    options: [
      OptionData(
        id: 'A',
        text: 'Refuse outright, because working hours are over and family rights are protected by law.',
        score: 1,
      ),
      OptionData(
        id: 'B',
        text:
            'Accept the urgent task responsibly, call your family to explain, and finish the '
            'verification carefully before going home.',
        score: 5,
      ),
      OptionData(
        id: 'C',
        text: 'Take the documents home and work on them late at night after the party.',
        score: 4,
      ),
      OptionData(
        id: 'D',
        text: 'Ask a single colleague to take over in exchange for buying them lunch tomorrow.',
        score: 3,
      ),
      OptionData(
        id: 'E',
        text: 'Rush through half of the documents so you can still make it to the party.',
        score: 2,
      ),
    ],
  ),
  QuestionData(
    id: 15,
    category: 'TKP',
    questionText:
        "In the staff's internal chat group, a colleague posts a provocative opinion that "
        'discredits the foundation of the state and calls for rejecting the regional '
        'election. You...',
    options: [
      OptionData(
        id: 'A',
        text: 'Reply in the group at once with harsh words to defend the regional leadership.',
        score: 1,
      ),
      OptionData(
        id: 'B',
        text:
            'Remind the group politely but firmly that civil servants are sworn to Pancasila and '
            'an official group is no place for hoaxes or sectarian issues, and report it to '
            'your supervisor.',
        score: 5,
      ),
      OptionData(
        id: 'C',
        text: 'Leave the official group at once to stay out of the debate.',
        score: 2,
      ),
      OptionData(
        id: 'D',
        text: 'Message the colleague privately to delete the post before the authorities notice.',
        score: 4,
      ),
      OptionData(
        id: 'E',
        text: 'Save a screenshot and spread it on social media so the colleague faces social sanctions.',
        score: 3,
      ),
    ],
  ),
];
