package com.sunesra_app

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream

/**
 * Puts the Azaan the reader chose into the phone's own **ringtone list**.
 *
 * The list Settings reads for "Phone ringtone" is a query over
 * [MediaStore.Audio.Media] for rows flagged `IS_RINGTONE`, and the app had
 * never written one: the clip lived inside the APK, where no picker can see
 * it, so the only way to hand it to the system was as an *alarm* sound —
 * which is the complaint this answers. An alarm rides a slider of its own,
 * one the volume rocker does not move, while a ringtone rides the ringer's —
 * the very number the keys adjust. Getting the file into the ringtone list
 * is what gets the sound under the reader's own hand.
 *
 * Two routes, ending in the same row:
 *
 *  * Android 10 and newer — the row goes straight into `MediaStore` with
 *    `RELATIVE_PATH = Ringtones` and the flags spelled out. Nothing is
 *    asked: the app owns what it creates, which is the whole idea behind
 *    scoped storage.
 *  * Android 7 to 9 — one file in the public `Ringtones/` folder, which
 *    those versions still gate behind a runtime permission. [MainActivity]
 *    asks for it before this side is reached, and a refusal never arrives
 *    here.
 *
 * The bytes are the ones the player itself would play — the owner's
 * downloaded clip first, the bundled one next — so the list cannot carry a
 * different Azaan from the one a reminder recites, and an old download can
 * never be the copy the phone rings with while the app recites something
 * else.
 *
 * One row per name. A second tap refills the row it finds instead of
 * stacking a second "Noor Azaan" line into the picker, which is also how a
 * changed clip replaces itself in place of growing the list.
 */
object PhoneRingtones {

    private const val TAG = "Noor/PhoneRingtones"

    /** What the clip's own bytes say it is. */
    private data class Format(val mime: String, val ext: String)

    /** Where one copy ended: the row, the name it landed as, and its age. */
    private data class Placed(val uri: Uri?, val name: String, val added: Boolean)

    /**
     * Everything the shipped clips and every owner upload this app has ever
     * taken are mp3s, so "unreadable header" lands here rather than in an
     * error: only the file name's suffix is a guess, and MediaPlayer sniffs
     * the bytes themselves for the part that matters.
     */
    private val MP3 = Format("audio/mpeg", "mp3")

    /**
     * Copies the clip named [sound] into the phone's ringtone list, titled
     * [title] there.
     *
     * The title arrives from Dart — it is UI copy, and the label beside the
     * clip in Settings is what the reader should recognise in the phone's
     * list too. Only its file-name half is cleaned up on this side.
     *
     * The returned map is the sentence Settings will speak: `title` quoted
     * back, the `displayName` the entry landed as, `uri` when MediaStore
     * holds one, and `added` — false when the list already carried this
     * title, which is not a failure but a different thing to tell.
     */
    fun addToPhoneRingtone(context: Context, sound: String, title: String): Map<String, Any?> {
        val app = context.applicationContext

        // The same precedence AzaanAudio.play walks: the owner's download
        // first, because a file sitting in filesDir *is* the clip the alarm
        // would play, and the bundled one only where there is none. One
        // resolution for both or the list could drift from the recitation.
        val cached = AzaanAudio.cachedClip(app, sound)
        val downloaded = cached.isFile && cached.length() > 0L
        val resId = if (downloaded) 0 else AzaanAudio.bundledId(app, sound)
        if (!downloaded && resId == 0) {
            throw IOException("no clip for $sound — neither a download nor res/raw")
        }

        val stem = sanitize(title)
        val source: InputStream =
            if (downloaded) FileInputStream(cached) else app.resources.openRawResource(resId)

        val placed: Placed = source.use { raw ->
            val stream = BufferedInputStream(raw, 16 * 1024)
            val format = sniff(stream)
            val displayName = "$stem.${format.ext}"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                fromMediaStore(app, stream, title, displayName, format)
            } else {
                fromRingtonesFolder(app, stream, title, displayName, format)
            }
        }
        return mapOf(
            "title" to title,
            "displayName" to placed.name,
            "uri" to placed.uri?.toString(),
            "added" to placed.added,
        )
    }

    /**
     * Android 10 and newer: one row in `MediaStore`, flagged for both lists
     * the clip has ever belonged to, sitting in the `Ringtones/` folder
     * every phone's own picker reads from.
     *
     * The insert is skipped when the name is already there — the bytes are
     * then rewritten through the row's own stream (`"wt"`, which truncates,
     * so a changed clip replaces itself rather than leaving the old
     * recording under the new one). That lookup is what keeps one tap from
     * becoming two identical lines in the picker.
     */
    private fun fromMediaStore(
        app: Context,
        stream: InputStream,
        title: String,
        displayName: String,
        format: Format,
    ): Placed {
        val base = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

        val known = findId(app, base, "${MediaStore.Audio.Media.DISPLAY_NAME} = ?", displayName)
        val uri = if (known != null) {
            ContentUris.withAppendedId(base, known)
        } else {
            app.contentResolver.insert(
                base,
                ContentValues().apply {
                    put(MediaStore.Audio.Media.DISPLAY_NAME, displayName)
                    put(MediaStore.Audio.Media.TITLE, title)
                    put(MediaStore.Audio.Media.MIME_TYPE, format.mime)
                    // The flag the whole feature hangs on: "Phone ringtone"
                    // is a query for rows carrying it, and without it the
                    // clip stays reachable only where the volume rocker does
                    // not go — as an alarm sound.
                    put(MediaStore.Audio.Media.IS_RINGTONE, 1)
                    // Kept as an alarm too: that is where the clip could be
                    // reached before this existed, and adding one list must
                    // not cost the other.
                    put(MediaStore.Audio.Media.IS_ALARM, 1)
                    put(MediaStore.Audio.Media.RELATIVE_PATH, Environment.DIRECTORY_RINGTONES)
                },
            ) ?: throw IOException("MediaStore refused the row for $displayName")
        }

        val out = app.contentResolver.openOutputStream(uri, "wt")
            ?: throw IOException("no stream for $uri")
        out.use { sink -> stream.copyTo(sink) }

        Log.i(
            TAG,
            "$displayName — ${if (known != null) "refreshed in" else "added to"} the ringtone list",
        )
        return Placed(uri, displayName, added = known == null)
    }

    /**
     * Android 7 to 9's route: one file in the public `Ringtones/` folder.
     *
     * The folder is half the feature — the system's own scanner treats what
     * sits in it as ringtone material — and the MediaStore row written next
     * spells the flags out so the picker does not have to wait for that scan
     * to agree. The write comes first and truncates, so a re-tap leaves
     * fresh bytes; the row is looked up by path for the same reason the
     * modern path looks one up by name: one tap, one line.
     */
    @Suppress("DEPRECATION") // the folder and the DATA column are both pre-Android 10 API
    private fun fromRingtonesFolder(
        app: Context,
        stream: InputStream,
        title: String,
        displayName: String,
        format: Format,
    ): Placed {
        val folder = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_RINGTONES)
        if (!folder.isDirectory && !folder.mkdirs()) {
            throw IOException("no writable ${folder.path} on this phone")
        }
        val file = File(folder, displayName)
        file.outputStream().use { sink -> stream.copyTo(sink) }

        val base = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val known = findId(app, base, "${MediaStore.Audio.Media.DATA} = ?", file.absolutePath)
        if (known != null) {
            Log.i(TAG, "$displayName — refreshed in the ringtone list")
            return Placed(ContentUris.withAppendedId(base, known), displayName, added = false)
        }

        val uri = app.contentResolver.insert(
            base,
            ContentValues().apply {
                put(MediaStore.Audio.Media.DATA, file.absolutePath)
                put(MediaStore.Audio.Media.TITLE, title)
                put(MediaStore.Audio.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Audio.Media.MIME_TYPE, format.mime)
                put(MediaStore.Audio.Media.IS_RINGTONE, 1)
                put(MediaStore.Audio.Media.IS_ALARM, 1)
            },
        )
        if (uri == null) {
            // The file is in the folder the picker reads either way, and the
            // scanner tags that folder's own contents as ringtones — a row
            // that refuses costs the entry number, not the ringtone.
            MediaScannerConnection.scanFile(
                app,
                arrayOf(file.absolutePath),
                arrayOf(format.mime),
                null,
            )
            Log.w(TAG, "no MediaStore row for $displayName — the folder itself carries it")
            return Placed(null, displayName, added = true)
        }
        Log.i(TAG, "$displayName — added to the ringtone list")
        return Placed(uri, displayName, added = true)
    }

    /** The row's id under [selection], or null — a lookup, not a verdict. */
    private fun findId(app: Context, base: Uri, selection: String, argument: String): Long? =
        try {
            app.contentResolver.query(
                base,
                arrayOf(MediaStore.Audio.Media._ID),
                selection,
                arrayOf(argument),
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getLong(0) else null
            }
        } catch (_: Exception) {
            // A query this build refuses reads as "no row yet"; the insert
            // below answers for itself if that guess was wrong.
            null
        }

    /**
     * Reads the clip's first bytes for the extension the list will show,
     * then gives those bytes back — `mark`/`reset` on our own buffered
     * stream, so the copy below starts at byte zero as if nothing had been
     * asked.
     *
     * The two formats the app itself ships are read exactly (azaan1..3 are
     * mp3, beep is wav), then the ones an owner's uploaded clip usually
     * arrives as. Everything else falls through to [MP3].
     */
    private fun sniff(stream: InputStream): Format {
        stream.mark(64)
        val head = ByteArray(12)
        var read = 0
        while (read < head.size) {
            val got = stream.read(head, read, head.size - read)
            if (got < 0) break
            read += got
        }
        stream.reset()
        return when {
            ascii(head, 0, 4) == "RIFF" && ascii(head, 8, 4) == "WAVE" -> Format("audio/wav", "wav")
            ascii(head, 0, 4) == "OggS" -> Format("audio/ogg", "ogg")
            ascii(head, 0, 4) == "fLaC" -> Format("audio/flac", "flac")
            ascii(head, 4, 4) == "ftyp" -> Format("audio/mp4", "m4a")
            else -> MP3
        }
    }

    /** A title that survives being a file name as well as a line in a list. */
    private fun sanitize(title: String): String =
        title
            .replace(Regex("""[\\/:*?"<>|]"""), "-")
            .trim()
            .ifEmpty { "Noor Azaan" }

    private fun ascii(bytes: ByteArray, from: Int, count: Int): String =
        if (bytes.size >= from + count) String(bytes, from, count, Charsets.US_ASCII) else ""
}
