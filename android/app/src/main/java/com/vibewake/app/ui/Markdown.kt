package com.vibewake.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp

/**
 * Just enough Markdown for Claude's replies: headings, lists, quotes, fenced code,
 * tables (shown as code), and inline **bold**, *italic*, `code` and [links](…).
 */
@Composable
fun Markdown(text: String, modifier: Modifier = Modifier) {
    val blocks = remember(text) { parseBlocks(text) }
    val codeBg = MaterialTheme.colorScheme.surfaceVariant
    val inlineCode = codeBg
    SelectionContainer(modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (b in blocks) when (b) {
                is Block.Heading -> Text(
                    inline(b.text, inlineCode),
                    style = if (b.level <= 2) MaterialTheme.typography.titleMedium else MaterialTheme.typography.titleSmall,
                )
                is Block.Code -> Text(
                    b.text,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(codeBg, RoundedCornerShape(6.dp))
                        .horizontalScroll(rememberScrollState())
                        .padding(10.dp),
                    softWrap = false,
                )
                is Block.Item -> Row(Modifier.padding(start = (b.indent * 12).dp)) {
                    Text(b.marker + " ", style = MaterialTheme.typography.bodyMedium)
                    Text(inline(b.text, inlineCode), style = MaterialTheme.typography.bodyMedium)
                }
                is Block.Quote -> Text(
                    inline(b.text, inlineCode),
                    style = MaterialTheme.typography.bodyMedium,
                    fontStyle = FontStyle.Italic,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 10.dp),
                )
                is Block.Para -> Text(inline(b.text, inlineCode), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

private sealed interface Block {
    data class Heading(val level: Int, val text: String) : Block
    data class Code(val text: String) : Block
    data class Item(val marker: String, val text: String, val indent: Int) : Block
    data class Quote(val text: String) : Block
    data class Para(val text: String) : Block
}

private val bullet = Regex("""^(\s*)([-*+]|\d+[.)])\s+(.*)$""")

private fun parseBlocks(src: String): List<Block> {
    val out = mutableListOf<Block>()
    val lines = src.lines()
    var i = 0
    val para = StringBuilder()
    fun flush() {
        if (para.isNotBlank()) out += Block.Para(para.toString().trim())
        para.clear()
    }
    while (i < lines.size) {
        val line = lines[i]
        val t = line.trimStart()
        when {
            t.startsWith("```") -> {
                flush()
                val code = StringBuilder()
                i++
                while (i < lines.size && !lines[i].trimStart().startsWith("```")) code.appendLine(lines[i++])
                out += Block.Code(code.toString().trimEnd())
            }
            t.startsWith("|") -> {
                flush()
                val table = StringBuilder()
                while (i < lines.size && lines[i].trimStart().startsWith("|")) table.appendLine(lines[i++])
                out += Block.Code(table.toString().trimEnd())
                continue
            }
            t.startsWith("#") -> {
                flush()
                val level = t.takeWhile { it == '#' }.length
                out += Block.Heading(level, t.drop(level).trim())
            }
            t.startsWith(">") -> {
                flush()
                out += Block.Quote(t.removePrefix(">").trim())
            }
            bullet.matches(line) -> {
                flush()
                val m = bullet.find(line)!!
                val marker = m.groupValues[2].let { if (it.first().isDigit()) it else "•" }
                out += Block.Item(marker, m.groupValues[3], m.groupValues[1].length / 2)
            }
            t.isEmpty() -> flush()
            else -> para.append(if (para.isEmpty()) t else " $t")
        }
        i++
    }
    flush()
    return out
}

private val inlinePattern = Regex("""`([^`]+)`|\*\*([^*]+)\*\*|\*([^*\s][^*]*)\*|\[([^\]]+)]\(([^)]+)\)""")

private fun inline(text: String, codeBg: Color): AnnotatedString = buildAnnotatedString {
    var last = 0
    for (m in inlinePattern.findAll(text)) {
        append(text.substring(last, m.range.first))
        val (code, bold, italic, linkText) = m.destructured
        when {
            code.isNotEmpty() -> withStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = codeBg)) { append(code) }
            bold.isNotEmpty() -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(bold) }
            italic.isNotEmpty() -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(italic) }
            linkText.isNotEmpty() -> withStyle(SpanStyle(fontWeight = FontWeight.Medium)) { append(linkText) }
        }
        last = m.range.last + 1
    }
    append(text.substring(last))
}
