package io.github.junweiup.vibepier.remote

import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.AdaptiveIconDrawable
import android.os.Build
import java.io.File

/** Renders shipped adaptive resources; no real app/session/transport is started. */
object BrandAssetsProbe {
    fun run(test: Instrumentation): String {
        check(BuildConfig.DESIGN_REVIEW && Build.MODEL.contains("sdk", true))
        val context = test.targetContext
        val icon = context.getDrawable(R.mipmap.ic_launcher) as AdaptiveIconDrawable
        val foreground = requireNotNull(icon.foreground)
        check(icon.background != null)
        val monochrome = if (Build.VERSION.SDK_INT >= 33) requireNotNull(icon.monochrome) else context.getDrawable(R.drawable.ic_launcher_monochrome)!!
        val sheet = Bitmap.createBitmap(900, 460, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(sheet)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 23f }
        for ((row, background) in listOf(Color.rgb(247, 248, 248), Color.rgb(31, 35, 38)).withIndex()) {
            paint.color = background; canvas.drawRect(0f, row * 230f, 900f, (row + 1) * 230f, paint)
            paint.color = if (row == 0) Color.BLACK else Color.WHITE
            canvas.drawText("VibePier · native icon fixtures · synthetic", 24f, row * 230f + 36f, paint)
            for ((column, size) in listOf(16, 32, 48, 96).withIndex()) {
                val tile = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                icon.setBounds(0, 0, size, size); icon.draw(Canvas(tile))
                check((0 until size).any { x -> (0 until size).any { y -> Color.alpha(tile.getPixel(x, y)) > 0 } })
                canvas.drawBitmap(tile, 28f + column * 150f, row * 230f + 64f, null)
                canvas.drawText("${size}px", 24f + column * 150f, row * 230f + 205f, paint)
                tile.recycle()
            }
            val mono = Bitmap.createBitmap(108, 108, Bitmap.Config.ARGB_8888)
            monochrome.setTint(if (row == 0) Color.BLACK else Color.WHITE)
            monochrome.setBounds(0, 0, 108, 108); monochrome.draw(Canvas(mono))
            // Android specifies a central 66dp safe circle in the 108dp foreground canvas.
            var ink = 0
            for (x in 0 until 108) for (y in 0 until 108) if (Color.alpha(mono.getPixel(x, y)) > 32) {
                ink++
                check((x - 54) * (x - 54) + (y - 54) * (y - 54) <= 33 * 33) { "Foreground escapes adaptive safe circle at $x,$y" }
            }
            check(ink > 100)
            canvas.drawBitmap(mono, 656f, row * 230f + 64f, null)
            canvas.drawText("monochrome", 635f, row * 230f + 205f, paint)
            mono.recycle()
            foreground.setBounds(0, 0, 108, 108)
        }
        File(context.externalCacheDir, "brand-icons.png").outputStream().use { sheet.compress(Bitmap.CompressFormat.PNG, 100, it) }
        sheet.recycle()
        return "PASS: shipped Android adaptive/monochrome drawables at 16/32/48/96px, light/dark fixtures and safe-circle bounds; no live state\n"
    }
}
