import 'package:flutter/material.dart';

void main() {
  runApp(const PlannerApp(
    title: 'Planner — Tasks',
    color: Colors.indigo,
    body: TasksPage(),
  ));
}

@pragma('vm:entry-point')
void calendarMain() {
  runApp(const PlannerApp(
    title: 'Planner — Calendar',
    color: Colors.teal,
    body: CalendarPage(),
  ));
}

class PlannerApp extends StatelessWidget {
  const PlannerApp({
    super.key,
    required this.title,
    required this.color,
    required this.body,
  });

  final String title;
  final Color color;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: title,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: color),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: Text(title),
        ),
        body: body,
      ),
    );
  }
}

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  final List<_Task> _tasks = [
    _Task('Design multi-window architecture'),
    _Task('Implement macOS runner'),
    _Task('Implement iOS scene delegates'),
    _Task('Write BUILD.bazel rules'),
    _Task('Test on iPad simulator'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: _tasks.length,
      itemBuilder: (context, index) {
        final task = _tasks[index];
        return CheckboxListTile(
          title: Text(
            task.title,
            style: TextStyle(
              decoration: task.done ? TextDecoration.lineThrough : null,
            ),
          ),
          value: task.done,
          onChanged: (value) {
            setState(() => task.done = value ?? false);
          },
        );
      },
    );
  }
}

class _Task {
  _Task(this.title, {this.done = false});
  final String title;
  bool done;
}

class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final firstDay = DateTime(now.year, now.month, 1);
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    // Monday = 1, Sunday = 7. Offset so Monday is column 0.
    final startWeekday = (firstDay.weekday - 1) % 7;

    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            '${_monthName(now.month)} ${now.year}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Row(
            children: weekdays
                .map((d) => Expanded(
                      child: Center(
                        child: Text(d,
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
              ),
              itemCount: startWeekday + daysInMonth,
              itemBuilder: (context, index) {
                if (index < startWeekday) return const SizedBox.shrink();
                final day = index - startWeekday + 1;
                final isToday = day == now.day;
                return Center(
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: isToday
                        ? BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                          )
                        : null,
                    alignment: Alignment.center,
                    child: Text(
                      '$day',
                      style: TextStyle(
                        color: isToday
                            ? Theme.of(context).colorScheme.onPrimary
                            : null,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _monthName(int month) {
    const names = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return names[month - 1];
  }
}
