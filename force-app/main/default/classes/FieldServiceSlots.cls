/**
 * FieldServiceSlots — offer bookable arrival windows to a web customer.
 * Primary: a deterministic generator (next N business days x AM/PM windows) that works
 * WITHOUT ES&O. If/when Enhanced Scheduling & Optimization is provisioned, swap in
 * FSL.AppointmentBookingService.getSlots(saId, policyId, operatingHoursId) for true,
 * candidate-aware slots. Returns ISO starts the agent feeds back into Book Maintenance Visit.
 */
public with sharing class FieldServiceSlots {

    public class Slot {
        public Datetime startTime;
        public Datetime endTime;
        public String iso;     // pass this as slotStart to FsBookVisit
        public String label;   // human friendly
    }

    public static List<Slot> generate(Integer daysAhead) {
        Integer n = (daysAhead == null || daysAhead <= 0) ? 5 : daysAhead;
        List<Slot> slots = new List<Slot>();
        Date d = Date.today().addDays(1);
        Integer found = 0;
        // window definitions: AM 9-12, PM 13-16
        List<Integer> startHours = new List<Integer>{ 9, 13 };
        while (found < n) {
            Datetime probe = Datetime.newInstance(d, Time.newInstance(12, 0, 0, 0));
            String dow = probe.format('EEE');
            if (dow != 'Sat' && dow != 'Sun') {
                for (Integer h : startHours) {
                    Slot s = new Slot();
                    s.startTime = Datetime.newInstance(d, Time.newInstance(h, 0, 0, 0));
                    s.endTime = s.startTime.addHours(3);
                    s.iso = s.startTime.formatGMT('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
                    s.label = s.startTime.format('EEE MMM d') + (h < 12 ? ', morning (9:00–12:00)' : ', afternoon (1:00–4:00)');
                    slots.add(s);
                }
                found++;
            }
            d = d.addDays(1);
        }
        return slots;
    }

    // Slice a REAL available interval (from FSL.GetSlots) into pickable AM/PM arrival windows.
    public static List<Slot> sliceInterval(Datetime windowStart, Datetime windowEnd) {
        List<Slot> out = new List<Slot>();
        if (windowStart == null || windowEnd == null) return out;
        Date d = windowStart.date();
        // candidate arrival windows: 9–12 and 13–16, only if they fall inside the real available interval
        for (Integer h : new List<Integer>{ 9, 13 }) {
            Datetime ws = Datetime.newInstance(d, Time.newInstance(h, 0, 0, 0));
            Datetime we = ws.addHours(3);
            if (ws >= windowStart && ws < windowEnd) {
                Slot s = new Slot();
                s.startTime = ws; s.endTime = we;
                s.iso = ws.formatGMT('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
                s.label = ws.format('EEE MMM d') + (h < 12 ? ', morning (9:00–12:00)' : ', afternoon (1:00–4:00)');
                out.add(s);
            }
        }
        return out;
    }

    // A summary string the agent reads to the customer, with ISO starts embedded so it can re-book the chosen one.
    public static String summarize(List<Slot> slots) {
        if (slots == null || slots.isEmpty()) return 'I don\'t have any open windows right now.';
        List<String> lines = new List<String>();
        Integer i = 1;
        for (Slot s : slots) {
            lines.add(i + ') ' + s.label + ' [' + s.iso + ']');
            i++;
        }
        return 'Here are the next available windows:\n' + String.join(lines, '\n')
            + '\nReply with the number you\'d like and I\'ll book it.';
    }
}
