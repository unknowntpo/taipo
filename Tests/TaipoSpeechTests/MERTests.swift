import Testing
@testable import TaipoSpeech

let reference = "這個 API 的 timeout 有點 short"

@Test("S1: normalization drops punctuation and whitespace, folds full-width and case")
func normalization() {
    #expect(MER.tokenize("ＡＰＩ，Ｔｉｍｅｏｕｔ！　好。") == ["api", "timeout", "好"])
    #expect(MER.tokenize("我晚點要 deploy，你先幫我看 log")
        == ["我", "晚", "點", "要", "deploy", "你", "先", "幫", "我", "看", "log"])
    #expect(MER.tokenize("  ，。！？  ") == [])
}

@Test("S1: Han characters are one token each; letter and digit runs are one token")
func tokenization() {
    #expect(MER.tokenize(reference) == ["這", "個", "api", "的", "timeout", "有", "點", "short"])
    #expect(MER.tokenize("這個API的timeout有點short") == MER.tokenize(reference))
    #expect(MER.tokenize("九點半 9:30 Kafka3") == ["九", "點", "半", "9", "30", "kafka3"])
    #expect(MER.tokenize("consumer group") == ["consumer", "group"])
}

@Test("S2: MER is edit distance over reference token count")
func rate() {
    #expect(MER.editDistance(["a", "b", "c"], ["a", "x", "c", "d"]) == 2)
    #expect(MER.rate(reference: reference, hypothesis: reference) == 0)
    #expect(MER.rate(reference: reference, hypothesis: "這個API的timeout有點short") == 0)
    #expect(MER.rate(reference: reference, hypothesis: "") == 1)
    #expect(MER.rate(reference: reference, hypothesis: "這個 API 的 timeout 有點") == 1.0 / 8)
    #expect(MER.errors(reference: reference, hypothesis: "那個 API timeout 有點 short 啊") == (errors: 3, tokens: 8))
}

@Test("S3: simplified output counts as errors; Example row two is 3/8")
func simplified() {
    #expect(MER.rate(reference: reference, hypothesis: "这个 API 的 timeout 有点 short") == 3.0 / 8)
    #expect(MER.rate(reference: reference, hypothesis: "這個 API 的 timeout 有點 short") == 0)
}
