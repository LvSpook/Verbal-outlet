/// Small date formatting helpers shared across screens.
///
/// These are intentionally hand-written instead of pulling in `intl` for now;
/// when localisation matters we can swap them for `intl`'s `DateFormat`.
library;

const monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const shortMonthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const weekdayInitials = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

const weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String formatClock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

String formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// "Today", "Yesterday", or "12 November 2026".
String formatDayTitle(DateTime day, {DateTime? relativeTo}) {
  final now = relativeTo ?? DateTime.now();
  final start = DateTime(now.year, now.month, now.day);
  final target = DateTime(day.year, day.month, day.day);
  final difference = start.difference(target).inDays;

  if (difference == 0) return 'Today';
  if (difference == 1) return 'Yesterday';
  if (difference == -1) return 'Tomorrow';
  return '${day.day} ${monthNames[day.month - 1]} ${day.year}';
}

/// "Thursday, 12 November" — the subtitle under the day title.
String formatDaySubtitle(DateTime day) =>
    '${weekdayNames[day.weekday - 1]}, '
    '${day.day} ${shortMonthNames[day.month - 1]}';

/// "12 Nov" or "12 Nov 2025" — compact, used for app bar titles.
String formatDayShort(DateTime day) {
  final thisYear = DateTime.now().year;
  final base = '${day.day} ${shortMonthNames[day.month - 1]}';
  return day.year == thisYear ? base : '$base ${day.year}';
}
