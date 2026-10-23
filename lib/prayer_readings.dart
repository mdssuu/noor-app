import 'package:flutter/foundation.dart';

// ===========================================================================
//  THE READING BETWEEN TWO PRAYERS
//
//  One hadith or one ayah on screen from the moment a prayer's time opens
//  until the moment the next prayer's opens — a different one every day, and
//  a different one for every prayer, with its reference attached.
//
//  Everything here is bundled: no network, no cache, no service to be down
//  at Fajr. The whole file is data plus one lookup, so the card above it
//  never has to decide anything except which language to print.
//
//  SOURCE OF THE QURAN ENTRIES — every ayah below (Arabic and all three
//  renderings) is taken verbatim from Quran.com:
//
//    • Arabic   — Uthmani script, as the mushaf on Quran.com prints it
//    • English  — Saheeh International
//    • Urdu     — Syed Abu Ali Maududi
//    • Roman    — Abul Ala Maududi, Roman Urdu (the same Maududi in Latin)
//
//  The hadith entries are not Quranic and keep their own sources.
// ===========================================================================

/// Where the words on the card come from.
enum ReadingKind {
  /// A verse of the Quran — `source` is `Quran 4:103` style.
  quran,

  /// A hadith — `source` names the collection and the hadith number.
  hadith,
}

/// One reading, in every rendering the card can show.
///
/// Four fields rather than two because the card has to answer *whose words
/// are these* (source), *what do they say* (the three renderings), and a
/// reader who reads none of the three must still be able to recognise the
/// Arabic — it is the one text that never changes.
@immutable
class PrayerReading {
  const PrayerReading({
    required this.kind,
    required this.arabic,
    required this.english,
    required this.urdu,
    required this.roman,
    required this.source,
  });

  final ReadingKind kind;

  /// The Arabic, fully vowelled as the mushaf prints it (Quran.com Uthmani).
  final String arabic;

  /// English rendering of the meaning (Saheeh International via Quran.com).
  final String english;

  /// Urdu rendering, in Nastaliq (Maududi via Quran.com).
  final String urdu;

  /// The same Maududi Urdu, written in the Latin alphabet as Quran.com's
  /// Roman Urdu translation has it — the one script that can never fail to
  /// render.
  final String roman;

  /// `Quran 4:103`, `Sahih al-Bukhari 631`. Never left blank: a quotation
  /// without a source is a rumour.
  final String source;

  String translationFor(String languageKey) {
    switch (languageKey) {
      case kReadingLanguageEnglish:
        return english;
      case kReadingLanguageRoman:
        return roman;
      case kReadingLanguageUrdu:
      default:
        return urdu;
    }
  }

}

/// The languages the card can print a translation in, in the order the
/// toggle shows them.
const String kReadingLanguageUrdu = 'urdu';
const String kReadingLanguageEnglish = 'english';
const String kReadingLanguageRoman = 'roman';

const List<String> kReadingLanguageKeys = <String>[
  kReadingLanguageUrdu,
  kReadingLanguageEnglish,
  kReadingLanguageRoman,
];

/// Short labels for the toggle — the whole control has to fit in one line
/// beside the window header, so there is no room for full names.
const Map<String, String> kReadingLanguageLabels = <String, String>{
  kReadingLanguageUrdu: 'URDU',
  kReadingLanguageEnglish: 'ENGLISH',
  kReadingLanguageRoman: 'ROMAN',
};

bool languageIsRtl(String key) => key == kReadingLanguageUrdu;

/// The five prayer windows, keyed exactly like [LocalPrayerTimes.times].
///
/// `sunrise` is deliberately absent: it is not a prayer, it has no window of
/// its own to carry a reading through, and boards never publish it.
const List<String> kReadingPrayerKeys = <String>[
  'fajr',
  'dhuhr',
  'asr',
  'maghrib',
  'isha',
];

const Map<String, String> kReadingPrayerLabels = <String, String>{
  'fajr': 'Fajr',
  'dhuhr': 'Dhuhr',
  'asr': 'Asr',
  'maghrib': 'Maghrib',
  'isha': 'Isha',
};

// ---------------------------------------------------------------------------
//  THE POOLS
//
//  Six per prayer, so a reader who opens the app every day meets a fresh one
//  for nearly a week per prayer before anything repeats. The pools lean
//  towards their own hour — dawn verses under Fajr, night ones under Isha —
//  but every entry stands on its own wherever it lands.
//
//  Each Quran entry is Quran.com's own text: Uthmani Arabic, Saheeh
//  International in English, Maududi in Urdu and Maududi's Roman Urdu.
// ---------------------------------------------------------------------------

const List<PrayerReading> kFajrReadings = <PrayerReading>[
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'أَقِمِ ٱلصَّلَوٰةَ لِدُلُوكِ ٱلشَّمْسِ إِلَىٰ غَسَقِ ٱلَّيْلِ '
        'وَقُرْءَانَ ٱلْفَجْرِ ۖ إِنَّ قُرْءَانَ ٱلْفَجْرِ كَانَ مَشْهُودًا',


    english:
        'Establish prayer at the decline of the sun [from its meridian] until '
        'the darkness of the night and [also] the Qur’ān [i.e., recitation] '
        'of dawn. Indeed, the recitation of dawn is ever witnessed.',
    urdu:
        'نماز قائم کرو زوالِ آفتاب سے لے کر رات کے اندھیرے تک اور فجر کے قرآن '
        'کا بھی التزام کرو کیونکہ قرآنِ فجر مشہُود ہوتا ہے۔',
    roman:
        'Namaz qayam karo zawal-e-aftaab (declining of the sun) se lekar raat '
        'ke andhere tak, aur fajr ke Quran ka bhi intezam karo, kyunke Quran '
        'e fajr mashood (witnessed) hota hai.',
    source: 'Quran 17:78',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'كَانُوا۟ قَلِيلًا مِّنَ ٱلَّيْلِ مَا يَهْجَعُونَ وَبِٱلْأَسْحَارِ هُمْ '
        'يَسْتَغْفِرُونَ',


    english:
        'They used to sleep but little of the night, and in the hours before '
        'dawn they would ask forgiveness.',
    urdu:
        'راتوں کو کم ہی سوتے تھے۔ پھر وہی رات کے پچھلے پہروں میں معافی '
        'مانگتے تھے۔',
    roman:
        'Raaton(nights) ko kam hi sotey(sleep) thay, phir wahi raat ke pichle '
        'peharon mein maafi maangte thay.',
    source: 'Quran 51:17-18',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'قَالَ رَبِّ ٱجْعَل لِّىٓ ءَايَةً ۖ قَالَ ءَايَتُكَ أَلَّا تُكَلِّمَ '
        'ٱلنَّاسَ ثَلَـٰثَةَ أَيَّامٍ إِلَّا رَمْزًا ۗ وَٱذْكُر رَّبَّكَ '
        'كَثِيرًا وَسَبِّحْ بِٱلْعَشِىِّ وَٱلْإِبْكَـٰرِ',


    english:
        'He said, "My Lord, make for me a sign." He said, "Your sign is that '
        'you will not [be able to] speak to the people for three days except '
        'by gesture. And remember your Lord much and exalt [Him with praise] '
        'in the evening and the morning."',
    urdu:
        'عرض کیا مالک! پھر کوئی نشانی میرے لیے مقرر فرما دے۔ کہا” نشانی یہ '
        'ہے کہ تم تین دن تک لوگوں سے اشارہ کے سوا کوئی بات چیت نہ کرو '
        'گے(یا نہ کر سکو گے)۔ اِس دوران میں اپنے رب کو بہت یاد کرنا اور صبح '
        'وشام اس کی تسبیح کرتے رہنا“۔',
    roman:
        'Arz kiya “Maalik! Phir koi nishani mere liye muqarrar farma de”. '
        'Kaha, Nishani yeh hai ke tum teen din tak logon se isharey ke siwa '
        'koi baat-chit na karoge (ya na kar sakoge), is dauraan mein apne '
        'Rubb ko bahut yaad karna aur subah o sham uski tasbeeh karte rehna.”',
    source: 'Quran 3:41',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'قَدْ أَفْلَحَ مَن تَزَكَّىٰ وَذَكَرَ ٱسْمَ رَبِّهِۦ فَصَلَّىٰ',


    english:
        'He has certainly succeeded who purifies himself and mentions the '
        'name of his Lord and prays.',
    urdu:
        'فلاح پا گیا وہ جس نے پاکیزگی اختیار کی اور اپنے ربّ کا نام یاد کیا '
        'پھر نماز پڑھی۔',
    roman:
        'Falah paa gaya woh jisne pakizgi ikhtiyar ki aur apne Rubb ka naam '
        'yaad kiya phir namaz padhi.',
    source: 'Quran 87:14-15',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'وَٱذْكُرِ ٱسْمَ رَبِّكَ بُكْرَةً وَأَصِيلًا',


    english:
        'And mention the name of your Lord [in prayer] morning and evening.',
    urdu: 'اپنے رب کا نام صبح و شام یاد کرو۔',
    roman: 'Apne Rubb ka naam subh-o-shaam yaad karo.',
    source: 'Quran 76:25',
  ),
  PrayerReading(
    kind: ReadingKind.hadith,
    arabic: 'إِنَّمَا الأَعْمَالُ بِالنِّيَّاتِ، وَإِنَّمَا لِكُلِّ امْرِئٍ مَا نَوَى',
    english:
        'Actions are but by intention, and every man will have only that which '
        'he intended.',
    urdu: 'امال نیت پر منحصر ہیں، اور ہر شخص کو وہی ملے گا جس کی اس نے نیت کی۔',
    roman:
        'Amal niyat par munhis hain, aur har ek ko wohi milega jis ki us ne '
        'niyat ki.',
    source: 'Sahih al-Bukhari 1',
  ),
];

const List<PrayerReading> kDhuhrReadings = <PrayerReading>[
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'فَإِذَا قَضَيْتُمُ ٱلصَّلَوٰةَ فَٱذْكُرُوا۟ ٱللَّهَ قِيَـٰمًا '
        'وَقُعُودًا وَعَلَىٰ جُنُوبِكُمْ ۚ فَإِذَا ٱطْمَأْنَنتُمْ فَأَقِيمُوا۟ '
        'ٱلصَّلَوٰةَ ۚ إِنَّ ٱلصَّلَوٰةَ كَانَتْ عَلَى ٱلْمُؤْمِنِينَ كِتَـٰبًا '
        'مَّوْقُوتًا',


    english:
        'And when you have completed the prayer, remember Allāh standing, '
        'sitting, or [lying] on your sides. But when you become secure, '
        're-establish [regular] prayer. Indeed, prayer has been decreed upon '
        'the believers a decree of specified times.',
    urdu:
        'پھر جب نماز سے فارغ ہو جاؤ تو کھڑے اور بیٹھے اور لیٹے، ہر حال میں '
        'اللہ کو یاد کرتے رہو اور جب اطمینان نصیب ہو جائے تو پوری نماز پڑھو '
        'نماز در حقیقت ایسا فرض ہے جو پابندی وقت کے ساتھ اہل ایمان پر لازم '
        'کیا گیا ہے۔',
    roman:
        'Phir jab namaz se farig ho jao to khade aur baithey aur letay, har '
        'haal mein Allah ko yaad karte raho aur jab itminaan naseeb ho jaye '
        'to poori namaz padho, namaz dar haqeeqat aisa farz hai jo pabandi e '
        'waqt ke saath ehle iman par lazim kiya gaya hai.',
    source: 'Quran 4:103',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'حَـٰفِظُوا۟ عَلَى ٱلصَّلَوَٰتِ وَٱلصَّلَوٰةِ ٱلْوُسْطَىٰ وَقُومُوا۟ '
        'لِلَّهِ قَـٰنِتِينَ',


    english:
        'Maintain with care the [obligatory] prayers and [in particular] the '
        'middle [i.e., ʿaṣr] prayer and stand before Allāh, devoutly '
        'obedient.',
    urdu:
        'اپنی نمازوں کی نگہداشت رکھو، خصوصاً ایسی نماز کی جو محاسِن صلوٰة کی '
        'جامع ہو۔ اللہ کے آگے اس طرح کھڑے ہو، جیسے فرماں بردار غلام کھڑے '
        'ہوتے ہیں۔',
    roman:
        'Apni namazon ki nigehdaasht rakkho, khususan aisi namaaz ki jo '
        'mohasan salawat ki jamey (middle prayer) ho. Allah ke aage is tarah '
        'khade ho jaise farmabardaar ghulam khade hotay hain.',
    source: 'Quran 2:238',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'وَأَقِمِ ٱلصَّلَوٰةَ طَرَفَىِ ٱلنَّهَارِ وَزُلَفًا مِّنَ ٱلَّيْلِ ۚ '
        'إِنَّ ٱلْحَسَنَـٰتِ يُذْهِبْنَ ٱلسَّيِّـَٔاتِ ۚ ذَٰلِكَ ذِكْرَىٰ '
        'لِلذَّٰكِرِينَ',


    english:
        'And establish prayer at the two ends of the day and at the approach '
        'of the night. Indeed, good deeds do away with misdeeds. That is a '
        'reminder for those who remember.',
    urdu:
        'اور دیکھو، نماز قائم کرو دن کے دونوں سروں پر اور کچھ رات گزرنے پر۔ '
        'در حقیقت نیکیاں برائیوں کو دور کردیتی ہیں، یہ ایک یاد دہانی ہے ان '
        'لوگوں کے لئے جو خدا کو یاد رکھنے والے ہیں۔',
    roman:
        'Aur dekho, namaz qayam karo din ke dono siron par (two ends of the '
        'day) aur kuch raat guzarne par. Dar haqeeqat nekiyan buraiyon ko '
        'door kar deti hain, yeh ek yaad dihani hai un logon ke liye jo khuda '
        'ko yaad rakhne waley hain.',
    source: 'Quran 11:114',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'ٱتْلُ مَآ أُوحِىَ إِلَيْكَ مِنَ ٱلْكِتَـٰبِ وَأَقِمِ ٱلصَّلَوٰةَ ۖ '
        'إِنَّ ٱلصَّلَوٰةَ تَنْهَىٰ عَنِ ٱلْفَحْشَآءِ وَٱلْمُنكَرِ ۗ '
        'وَلَذِكْرُ ٱللَّهِ أَكْبَرُ ۗ وَٱللَّهُ يَعْلَمُ مَا تَصْنَعُونَ',


    english:
        'Recite, [O Muḥammad], what has been revealed to you of the Book and '
        'establish prayer. Indeed, prayer prohibits immorality and '
        'wrongdoing, and the remembrance of Allāh is greater. And Allāh '
        'knows that which you do.',
    urdu:
        '(اے نبی ؐ) تلاوت کرو اس کتاب کی جو تمہاری طرف وحی کے ذریعے سے '
        'بھیجی گئی ہے۔ اور نماز قائم کرو، یقیناً نماز فحش اور بُرے کاموں سے '
        'روکتی ہے اور اللہ کا ذکر اس سے بھی زیادہ بڑی چیز ہے۔ اللہ جانتا ہے '
        'جو کچھ تم لوگ کرتے ہو۔',
    roman:
        '(Aey Nabi) Tilawat karo is kitaab ki jo tumhari taraf wahee ke '
        'zairye se bheji gayi hai. Aur namaz qayam karo, yaqeenan namaz '
        'fahash (behayayi) aur burey kaamon se rokti hai. Aur Allah ka zikr '
        'issey bhi zyada badi cheez hai. Allah jaanta hai jo kuch tumlog '
        'karte ho.',
    source: 'Quran 29:45',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'يَـٰٓأَيُّهَا ٱلَّذِينَ ءَامَنُوا۟ ٱسْتَعِينُوا۟ بِٱلصَّبْرِ '
        'وَٱلصَّلَوٰةِ ۚ إِنَّ ٱللَّهَ مَعَ ٱلصَّـٰبِرِينَ',


    english:
        'O you who have believed, seek help through patience and prayer. '
        'Indeed, Allāh is with the patient.',
    urdu:
        'اے لوگو جو ایمان لائے ہو صبر اور نماز سے مدد لو۔ اللہ صبر کرنے '
        'والوں کے ساتھ ہے۔',
    roman:
        'Aey logon jo iman laye ho sabr aur namaz se madad lo, Allah sabr '
        'karne walon ke saath hai.',
    source: 'Quran 2:153',
  ),
  PrayerReading(
    kind: ReadingKind.hadith,
    arabic: 'صَلُّوا كَمَا رَأَيْتُمُونِي أُصَلِّي',
    english: 'Pray as you have seen me praying.',
    urdu: 'ویسی نماز پڑھو جیسی تم نے میری نماز دیکھی ہے۔',
    roman: 'Waisi namaz padho jaisi tum ne meri namaz dekhi hai.',
    source: 'Sahih al-Bukhari 631',
  ),
];

const List<PrayerReading> kAsrReadings = <PrayerReading>[
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'إِنَّآ أَعْطَيْنَـٰكَ ٱلْكَوْثَرَ فَصَلِّ لِرَبِّكَ وَٱنْحَرْ',


    english:
        'Indeed, We have granted you, [O Muḥammad], al-Kawthar. So pray to '
        'your Lord and offer sacrifice [to Him alone].',
    urdu:
        '(اے نبیؐ) ہم نے تمہیں کوثر عطا کر دیا۔ پس تم اپنے ربّ ہی کے لیے '
        'نماز پڑھو اور قربانی کرو۔',
    roman:
        '(Aey Nabi) Hum ne tumhein kausar ata kar diya. Pas tum apne Rubb '
        'hi ke liye namaz padho aur qurbani karo.',
    source: 'Quran 108:1-2',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'قُلْ إِنَّ صَلَاتِى وَنُسُكِى وَمَحْيَاىَ وَمَمَاتِى لِلَّهِ رَبِّ '
        'ٱلْعَـٰلَمِينَ',


    english:
        'Say, "Indeed, my prayer, my rites of sacrifice, my living and my '
        'dying are for Allāh, Lord of the worlds."',
    urdu:
        'کہو، میری نماز، میرے تمام مراسِم عبودیت، میرا جینا اور میرا مرنا، '
        'سب کچھ اللہ رب العالمین کے لیے ہے۔',
    roman:
        'Kaho, meri namaz, mere tamaam marasim ubudiyat (all my acts of '
        'worship), mera jeena aur mera marna, sab kuch Allah Rabbul Aalameen '
        'ke liye hai.',
    source: 'Quran 6:162',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'قَدْ أَفْلَحَ ٱلْمُؤْمِنُونَ ٱلَّذِينَ هُمْ فِى صَلَاتِهِمْ '
        'خَـٰشِعُونَ',


    english:
        'Certainly will the believers have succeeded: They who are during '
        'their prayer humbly intent.',
    urdu:
        'یقیناً فلاح پائی ہے ایمان لانے والوں نے جو اپنی نماز میں خشوع '
        'اختیار کرتے ہیں۔',
    roman:
        'Yaqeenan falaah payi hai iman laney walon ne jo apni namaz mein '
        'khushu ikhtiyar karte hain (Salat with humility).',
    source: 'Quran 23:1-2',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'يَـٰبُنَىَّ أَقِمِ ٱلصَّلَوٰةَ وَأْمُرْ بِٱلْمَعْرُوفِ وَٱنْهَ عَنِ '
        'ٱلْمُنكَرِ وَٱصْبِرْ عَلَىٰ مَآ أَصَابَكَ ۖ إِنَّ ذَٰلِكَ مِنْ عَزْمِ '
        'ٱلْأُمُورِ',


    english:
        'O my son, establish prayer, enjoin what is right, forbid what is '
        'wrong, and be patient over what befalls you. Indeed, [all] that is '
        'of the matters [requiring] resolve.',
    urdu:
        'بیٹا، نماز قائم کر، نیکی کا حکم دے، بدی سے منع کر، اور جو مصیبت '
        'بھی پڑے اس پر صبر کر۔ یہ وہ باتیں ہیں جن کی بڑی تاکید کی گئی ہے۔',
    roman:
        'Beta, namaz qayam kar, neki ka hukum de, badee (burai) se manah '
        'kar, aur jo museebat bhi padey uspar sabr kar, yeh woh baatein hain '
        'jinki badi takeed ki gayi hai.',
    source: 'Quran 31:17',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'إِلَّا ٱلْمُصَلِّينَ ٱلَّذِينَ هُمْ عَلَىٰ صَلَاتِهِمْ دَآئِمُونَ',


    english: 'Except the observers of prayer — those who are constant in their prayer.',
    urdu:
        'مگر وہ لوگ (اِس عیب سے بچے ہوئے ہیں) جو نماز پڑھنے والے ہیں، جو '
        'اپنی نماز کی ہمیشہ پابندی کرتے ہیں۔',
    roman:
        'Magar woh log (is aib se bache huey hai) jo namaz padne waley hain, '
        'jo apni namaz ki hamesha pabandi karte hain.',
    source: 'Quran 70:22-23',
  ),
  PrayerReading(
    kind: ReadingKind.hadith,
    arabic: 'أَحَبُّ الأَعْمَالِ إِلَى اللَّهِ أَدْوَمُهَا وَإِنْ قَلَّ',
    english:
        'The most beloved deeds to Allah are the most consistent, even if few.',
    urdu: 'اللہ کو سب سے پیارے اعمال وہ ہیں جو مسلسل ہوں، چاہے کم ہوں۔',
    roman: 'Allah ko sab se pyare amal wo hain jo musalsal hon, chahe kam hon.',
    source: 'Sahih al-Bukhari 6464',
  ),
];

const List<PrayerReading> kMaghribReadings = <PrayerReading>[
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'فَسُبْحَـٰنَ ٱللَّهِ حِينَ تُمْسُونَ وَحِينَ تُصْبِحُونَ',


    english:
        'So exalted is Allāh when you reach the evening and when you reach '
        'the morning.',
    urdu:
        'پس تسبیح کرو اللہ کی جبکہ تم شام کرتے ہو اور جب صبح کرتے ہو۔',
    roman:
        'Pas tasbeeh karo Allah ki jabke tum shaam karte ho aur jab subah '
        'karte ho.',
    source: 'Quran 30:17',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'فَٱصْبِرْ عَلَىٰ مَا يَقُولُونَ وَسَبِّحْ بِحَمْدِ رَبِّكَ قَبْلَ '
        'طُلُوعِ ٱلشَّمْسِ وَقَبْلَ غُرُوبِهَا ۖ وَمِنْ ءَانَآئِ ٱلَّيْلِ '
        'فَسَبِّحْ وَأَطْرَافَ ٱلنَّهَارِ لَعَلَّكَ تَرْضَىٰ',


    english:
        'So be patient over what they say and exalt [Allāh] with praise of '
        'your Lord before the rising of the sun and before its setting; and '
        'during periods of the night [exalt Him] and at the ends of the day, '
        'that you may be satisfied.',
    urdu:
        'پس اے محمدؐ، جو باتیں یہ لوگ بناتے ہیں اُن پر صبر کرو، اور اپنے '
        'ربّ کی حمد و ثنا کے ساتھ اُس کی تسبیح کرو سورج نکلنے سے پہلے اور '
        'غرُوب ہونے سے پہلے، اور رات کے اوقات میں بھی تسبیح کرو اور دن کے '
        'کناروں پر بھی، شاید کہ تم راضی ہو جاؤں۔',
    roman:
        'Pas (aey Muhammad), jo baatein yeh log banate hain unpar sabr karo, '
        'aur apne Rubb ki hamd o sana ke saath uski tasbeeh karo Suraj '
        'nikalne se pehle aur guroob honay se pehle, aur raat ke auqat mein '
        'bhi tasbeeh karo aur din ke kinaron par bhi, shayad ke tum raazi ho '
        'jao.',
    source: 'Quran 20:130',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'فَٱصْبِرْ عَلَىٰ مَا يَقُولُونَ وَسَبِّحْ بِحَمْدِ رَبِّكَ قَبْلَ '
        'طُلُوعِ ٱلشَّمْسِ وَقَبْلَ ٱلْغُرُوبِ',


    english:
        'So be patient, [O Muḥammad], over what they say and exalt [Allāh] '
        'with praise of your Lord before the rising of the sun and before '
        'its setting.',
    urdu:
        'پس اے نبیؐ، جو باتیں یہ لوگ بناتے ہیں ان پر صبر کرو، اور اپنے رب '
        'کی حمد کے ساتھ اس کی تسبیح کرتے رہو، طلوع آفتاب اور غروب آفتاب سے '
        'پہلے۔',
    roman:
        'Pas aey Nabi, jo baatein yeh log banate hain unpar sabr karo, aur '
        'apne Rubb ki hamd ke saath uski tasbeeh karte raho, tulu-e-aftaab '
        '(rising of the sun) aur guroob-e-aftaab (before its setting) se '
        'pehle.',
    source: 'Quran 50:39',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'فِى بُيُوتٍ أَذِنَ ٱللَّهُ أَن تُرْفَعَ وَيُذْكَرَ فِيهَا ٱسْمُهُۥ '
        'يُسَبِّحُ لَهُۥ فِيهَا بِٱلْغُدُوِّ وَٱلْـَٔاصَالِ',


    english:
        '[Such niches are] in houses [i.e., mosques] which Allāh has ordered '
        'to be raised and that His name be mentioned [i.e., praised] '
        'therein; exalting Him within them in the morning and the evenings.',
    urdu:
        '(اُس کے نُور کی طرف ہدایت پانے والے) اُن گھروں میں پائے جاتے ہیں '
        'جنہیں بلند کرنے کا، اور جن میں اپنے نام کی یاد کا اللہ نے اِذن دیا '
        'ہے۔',
    roman:
        '(Uske noor ki taraf hidayat paney waley) un gharon mein paye jatey '
        'hain jinhein buland karne ka aur jin mein apne naam ki yaad ka Allah '
        'ne izan (ijazat) diya hai.',
    source: 'Quran 24:36',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'وَمِنْهُم مَّن يَقُولُ رَبَّنَآ ءَاتِنَا فِى ٱلدُّنْيَا حَسَنَةً '
        'وَفِى ٱلْـَٔاخِرَةِ حَسَنَةً وَقِنَا عَذَابَ ٱلنَّارِ',


    english:
        'But among them is he who says, "Our Lord, give us in this world '
        '[that which is] good and in the Hereafter [that which is] good and '
        'protect us from the punishment of the Fire."',
    urdu:
        'اور کوئی کہتا ہے کہ اے ہمارے رب! ہمیں دنیا میں بھی بھلائی دے اور '
        'آخرت میں بھی بھلائی اور آگ کے عذاب سے ہمیں بچا۔',
    roman:
        'Aur koi kehta hai ke aey hamare Rubb! Humein duniya mein bhalayi de '
        'aur aakhirat mein bhi bhalayi, aur aag ke azaab se humein bacha.',
    source: 'Quran 2:201',
  ),
  PrayerReading(
    kind: ReadingKind.hadith,
    arabic: 'مَا نَقَصَتْ صَدَقَةٌ مِنْ مَالٍ',
    english: 'Charity does not decrease wealth.',
    urdu: 'صدقہ مال میں کمی نہیں لاتا۔',
    roman: 'Sadaqa maal mein kami nahi laata.',
    source: 'Sahih Muslim 2588',
  ),
];

const List<PrayerReading> kIshaReadings = <PrayerReading>[
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'يَـٰٓأَيُّهَا ٱلْمُزَّمِّلُ قُمِ ٱلَّيْلَ إِلَّا قَلِيلًا',


    english:
        'O you who wraps himself [in clothing], arise [to pray] the night, '
        'except for a little.',
    urdu:
        'اے اوڑھ لپیٹ کر سونے والے، رات کو نماز میں کھڑے رہا کرو مگر کم۔',
    roman:
        'Aey oad lapet kar (enwrapped) sone waley, raat ko namaz mein khade '
        'raha karo magar kam.',
    source: 'Quran 73:1-2',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'ٱلصَّـٰبِرِينَ وَٱلصَّـٰدِقِينَ وَٱلْقَـٰنِتِينَ وَٱلْمُنفِقِينَ '
        'وَٱلْمُسْتَغْفِرِينَ بِٱلْأَسْحَارِ',


    english:
        'The patient, the true, the obedient, those who spend [in the way of '
        'Allāh], and those who seek forgiveness before dawn.',
    urdu:
        'یہ لوگ صبر کرنے والے ہیں، راستباز ہیں، فرمانبردار اور فیاض ہیں اور '
        'رات کی آخری گھڑیوں میں اللہ سے مغفرت کی دعائیں مانگا کرتے ہیں۔',
    roman:
        'Yeh log sabr karne waley hain, raastbaaz hain, farmabardaar aur '
        'fayyaz hain aur raat ki aaakhri ghadiyon mein Allah se magfirat ki '
        'duaein maanga karte hain.',
    source: 'Quran 3:17',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'إِنَّ فِى خَلْقِ ٱلسَّمَـٰوَٰتِ وَٱلْأَرْضِ وَٱخْتِلَـٰفِ ٱلَّيْلِ '
        'وَٱلنَّهَارِ لَـَٔايَـٰتٍ لِّأُو۟لِى ٱلْأَلْبَـٰبِ ٱلَّذِينَ '
        'يَذْكُرُونَ ٱللَّهَ قِيَـٰمًا وَقُعُودًا وَعَلَىٰ جُنُوبِهِمْ '
        'وَيَتَفَكَّرُونَ فِى خَلْقِ ٱلسَّمَـٰوَٰتِ وَٱلْأَرْضِ رَبَّنَا مَا '
        'خَلَقْتَ هَـٰذَا بَـٰطِلًا سُبْحَـٰنَكَ فَقِنَا عَذَابَ ٱلنَّارِ',


    english:
        'Indeed, in the creation of the heavens and the earth and the '
        'alternation of the night and the day are signs for those of '
        'understanding — who remember Allāh while standing or sitting or '
        '[lying] on their sides and give thought to the creation of the '
        'heavens and the earth, [saying], "Our Lord, You did not create '
        'this aimlessly; exalted are You [above such a thing]; then protect '
        'us from the punishment of the Fire."',
    urdu:
        'زمین اور آسمانوں کی پیدائش میں اور رات اور دن کے باری باری سے '
        'آنے میں ان ہوشمند لوگوں کے لیے بہت نشانیاں ہیں، جو اٹھتے، بیٹھتے '
        'اور لیٹتے، ہر حال میں خدا کو یاد کرتے ہیں اور آسمان و زمین کی ساخت '
        'میں غورو فکر کرتے ہیں۔ ( وہ بے اختیار بول اٹھتے ہیں)”پروردگار! یہ '
        'سب کچھ تُو نے فضول اور بے مقصد نہیں بنایا ہے، تُو پاک ہے اس سے کہ '
        'عبث کا م کرے۔ پس اے رب! ہمیں دوزخ کے عذاب سے بچا لے،',
    roman:
        'Zameen aur asmaano ki paidaish mein aur raat aur din ke bari bari '
        'se aane mein un hoshmand logon ke liye bahut nishaniyan hain, jo '
        'uthte, baithte aur latetey, har haal mein khuda ko yaad karte hain '
        'aur asmaan o zameen ki saakht (creation) mein gaur o fikr karte '
        'hain. (Woh be-ikhtiyar bol uthte hain) “Parwardigar! Yeh sab kuch '
        'tu nay fizul aur be-maqsad nahin banaya hai, tu paak hai issey ke '
        'abas (bekar / in vain) kaam karey. Pas aey Rubb! Humein dozakh ke '
        'azaab se bacha le.',
    source: 'Quran 3:190-191',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'وَمِنَ ٱلَّيْلِ فَتَهَجَّدْ بِهِۦ نَافِلَةً لَّكَ عَسَىٰٓ أَن '
        'يَبْعَثَكَ رَبُّكَ مَقَامًا مَّحْمُودًا',


    english:
        'And from [part of] the night, pray with it [i.e., recitation of '
        'the Qur’ān] as additional [worship] for you; it is expected that '
        'your Lord will resurrect you to a praised station.',
    urdu:
        'اور رات کو تہجّد پڑھو، یہ تمہارے لیے نفل ہے، بعید نہیں کہ تمہارا '
        'ربّ تمہیں مقامِ محمُود پر فائز کر دے۔',
    roman:
        'Aur raat ko tahajjud padho, yeh tumhare liye nafl hai, baeed (door '
        '/far) nahin ke tumhara Rubb tumhein maqaam e mehmood par faiz '
        'karde.',
    source: 'Quran 17:79',
  ),
  PrayerReading(
    kind: ReadingKind.quran,
    arabic:
        'وَٱلَّذِينَ يَبِيتُونَ لِرَبِّهِمْ سُجَّدًا وَقِيَـٰمًا',


    english:
        'And those who spend [part of] the night to their Lord prostrating '
        'and standing [in prayer].',
    urdu:
        'جو اپنے ربّ کے حضور سجدے اور قیام میں راتیں گزارتے ہیں۔',
    roman:
        'Jo apne Rubb ke huzur sajde aur qayaam mein raatein guzarte hain.',
    source: 'Quran 25:64',
  ),
  PrayerReading(
    kind: ReadingKind.hadith,
    arabic: 'إِنَّ اللَّهَ رَفِيقٌ يُحِبُّ الرِّفْقَ فِي الأَمْرِ كُلِّهِ',
    english: 'Indeed, Allah is gentle and loves gentleness in all matters.',
    urdu: 'بے شک اللہ نرمی والا ہے اور ہر معاملے میں نرمی کو پسند کرتا ہے۔',
    roman:
        'Be shak Allah narmi wala hai aur har mamle mein narmi ko pasand '
        'karta hai.',
    source: 'Sahih Muslim 2165',
  ),
];

/// Every pool, keyed by prayer.
const Map<String, List<PrayerReading>> kReadingsByPrayer =
    <String, List<PrayerReading>>{
  'fajr': kFajrReadings,
  'dhuhr': kDhuhrReadings,
  'asr': kAsrReadings,
  'maghrib': kMaghribReadings,
  'isha': kIshaReadings,
};

/// The reading on show for [prayerKey] on [day] — the same answer for the
/// whole day, so the card never flips underneath a reader mid-prayer, and a
/// different one from tomorrow.
///
/// Day arithmetic rather than `DateTime.now().millisecondsSinceEpoch`: two
/// calls an hour either side of midnight must not disagree, and the tests
/// have to be able to ask what was on show yesterday.
PrayerReading readingFor(String prayerKey, DateTime day) {
  final List<PrayerReading> pool =
      kReadingsByPrayer[prayerKey] ?? kReadingsByPrayer['fajr']!;
  if (pool.isEmpty) {
    return kFajrReadings.first;
  }

  final DateTime midnight = DateTime(day.year, day.month, day.day);
  final int dayNumber =
      midnight.difference(DateTime(2000, 1, 1)).inDays; // fixed epoch, not DST
  return pool[dayNumber % pool.length];
}
