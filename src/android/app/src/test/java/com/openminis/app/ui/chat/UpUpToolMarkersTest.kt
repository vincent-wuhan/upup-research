package com.openminis.app.ui.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UpUpToolMarkersTest {

    @Test
    fun `start marker 解析为 RUNNING 动作`() {
        val markers = UpUpToolMarkers.extract("⟪upup-tool:start|get_astock_price⟫")!!
        assertEquals(1, markers.size)
        assertEquals("start", markers[0].action)
        assertEquals("get_astock_price", markers[0].name)
        assertNull(markers[0].ok)
    }

    @Test
    fun `end marker 携带成败状态`() {
        val ok = UpUpToolMarkers.extract("⟪upup-tool:end|get_astock_price|ok⟫")!!
        assertEquals(true, ok[0].ok)
        val failed = UpUpToolMarkers.extract("⟪upup-tool:end|shell_exec|failed⟫")!!
        assertEquals(false, failed[0].ok)
    }

    @Test
    fun `网关带首尾换行的独立 delta 可解析`() {
        val markers = UpUpToolMarkers.extract("\n⟪upup-tool:start|valuation_ratios⟫\n")!!
        assertEquals("valuation_ratios", markers[0].name)
    }

    @Test
    fun `一条 delta 内多个 marker 全部解析`() {
        val markers = UpUpToolMarkers.extract("⟪upup-tool:end|a|ok⟫⟪upup-tool:start|b⟫")!!
        assertEquals(2, markers.size)
        assertEquals("a", markers[0].name)
        assertEquals("b", markers[1].name)
    }

    @Test
    fun `混入正文的 marker 不吞正文`() {
        assertNull(UpUpToolMarkers.extract("结论如下：⟪upup-tool:start|a⟫ 仅供参考"))
    }

    @Test
    fun `普通文本不匹配`() {
        assertNull(UpUpToolMarkers.extract("贵州茅台当前 PE 21.5"))
        assertNull(UpUpToolMarkers.extract(""))
    }
}
