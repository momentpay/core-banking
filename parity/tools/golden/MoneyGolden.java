import java.io.IOException;
import java.io.PrintWriter;
import java.math.BigDecimal;
import java.math.MathContext;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import org.apache.fineract.infrastructure.core.domain.FineractPlatformTenant;
import org.apache.fineract.infrastructure.core.service.ThreadLocalContextUtil;
import org.apache.fineract.organisation.monetary.data.CurrencyData;
import org.apache.fineract.organisation.monetary.domain.Money;
import org.apache.fineract.organisation.monetary.domain.MoneyHelper;

/**
 * Generates golden-master cases for ecb_money by running Apache Fineract's own {@code Money} class.
 *
 * The expected value in every case is what Fineract computes, not what we think it computes. The
 * Elixir test replays the same inputs and requires identical results.
 *
 * Usage: java -cp "FINERACT_CLASSPATH" MoneyGolden.java OUTPUT.json [SEED] [CASES_PER_COMBINATION]
 *
 * A case records the tenant rounding mode (what MoneyHelper holds) and the MathContext rounding mode
 * passed to the operation. They are equal in normal use. Cases where they differ cover Fineract's
 * quirk of rounding "multiples of" amounts with the tenant mode but the final scale with the
 * MathContext mode.
 */
public class MoneyGolden {

    record Cur(String code, int places, Integer multiples) {
        CurrencyData data() {
            return new CurrencyData(code, places, multiples);
        }
    }

    static final Cur[] CURRENCIES = { new Cur("USD", 2, null), new Cur("JPY", 0, null), new Cur("KWD", 3, null),
            new Cur("ONE", 1, null), new Cur("XXX", 0, 5), new Cur("YYY", 0, 50), new Cur("ZZZ", 0, 0), new Cur("MUL", 2, 5) };

    // Tie-heavy and edge amounts, then random ones are added.
    static final String[] FIXED_AMOUNTS = { "0", "0.005", "0.015", "0.025", "0.035", "0.045", "0.5", "1.5", "2.5", "3.5", "-0.5", "-1.5", "-2.5",
            "-0.005", "-0.015", "1", "7.4", "7.5", "12.5", "12.49", "17.5", "22.5", "100", "1E+3", "0.0000001", "999999999999.995",
            "123456789012.345678", "-987654321.0049" };

    static final String[] FIXED_FACTORS = { "1", "0", "-1", "2", "3", "7", "0.5", "0.25", "0.125", "0.0125", "0.0049", "1.005", "12.5", "100", "0.3333333333333333333333",
            "0.6666666666666666666666666", "-0.07", "1000000" };

    static final String[] FIXED_DIVISORS = { "1", "2", "3", "7", "8", "0.5", "0.3", "12", "-4", "100", "365", "0.0001", "3.3333333333333333333333" };

    static final int[] MULTIPLES = { 1, 2, 5, 10, 25, 50, 100 };

    static final List<String> out = new ArrayList<>();
    static Random random;

    public static void main(String[] args) throws IOException {
        Path outFile = Path.of(args[0]);
        long seed = args.length > 1 ? Long.parseLong(args[1]) : 20261114L;
        int perCombo = args.length > 2 ? Integer.parseInt(args[2]) : 120;
        random = new Random(seed);

        ThreadLocalContextUtil.setTenant(new FineractPlatformTenant(1L, "default", "Default", "UTC", null));

        for (int tenantMode = 0; tenantMode <= 6; tenantMode++) {
            for (int mcMode = 0; mcMode <= 6; mcMode++) {
                // Same-mode cases are the normal case and get the full volume. Cross-mode cases are the quirk and get a lighter pass.
                boolean same = tenantMode == mcMode;
                if (!same && tenantMode != 6 && mcMode != tenantMode && random.nextInt(4) != 0) {
                    continue;
                }
                MoneyHelper.initializeTenantRoundingMode("default", tenantMode);
                MathContext mc = new MathContext(MoneyHelper.PRECISION, RoundingMode.valueOf(mcMode));
                for (Cur cur : CURRENCIES) {
                    int n = same ? perCombo : Math.max(10, perCombo / 6);
                    generate(cur, tenantMode, mcMode, mc, n);
                }
            }
        }

        try (PrintWriter w = new PrintWriter(Files.newBufferedWriter(outFile, StandardCharsets.UTF_8))) {
            w.println("[");
            for (int i = 0; i < out.size(); i++) {
                w.println("  " + out.get(i) + (i + 1 < out.size() ? "," : ""));
            }
            w.println("]");
        }
        System.out.println("Wrote " + out.size() + " cases to " + outFile);
    }

    static void generate(Cur cur, int tenantMode, int mcMode, MathContext mc, int n) {
        // constructor cases: every fixed amount, plus random ones
        for (String amount : FIXED_AMOUNTS) {
            record(cur, tenantMode, mcMode, "new", List.of(amount), () -> Money.of(cur.data(), new BigDecimal(amount), mc).toString());
        }
        for (int i = 0; i < n; i++) {
            String amount = randomDecimal();
            record(cur, tenantMode, mcMode, "new", List.of(amount), () -> Money.of(cur.data(), new BigDecimal(amount), mc).toString());
        }

        for (int i = 0; i < n; i++) {
            final String a = pickAmount();
            final String b = pickAmount();
            final String factor = pick(FIXED_FACTORS, 3);
            final String divisor = pick(FIXED_DIVISORS, 2);
            final int multiple = MULTIPLES[random.nextInt(MULTIPLES.length)];
            final String third = pickAmount();

            record(cur, tenantMode, mcMode, "plus", List.of(a, b), () -> money(cur, a, mc).plus(money(cur, b, mc)).toString());
            record(cur, tenantMode, mcMode, "plus_amount", List.of(a, b), () -> money(cur, a, mc).plus(new BigDecimal(b)).toString());
            record(cur, tenantMode, mcMode, "minus", List.of(a, b), () -> money(cur, a, mc).minus(money(cur, b, mc)).toString());
            record(cur, tenantMode, mcMode, "minus_amount", List.of(a, b), () -> money(cur, a, mc).minus(new BigDecimal(b)).toString());
            record(cur, tenantMode, mcMode, "times", List.of(a, factor), () -> money(cur, a, mc).multipliedBy(new BigDecimal(factor)).toString());
            record(cur, tenantMode, mcMode, "divide", List.of(a, divisor), () -> money(cur, a, mc).dividedBy(new BigDecimal(divisor), mc).toString());
            record(cur, tenantMode, mcMode, "percentage_of", List.of(a, factor), () -> money(cur, a, mc).percentageOf(new BigDecimal(factor), mc).toString());
            record(cur, tenantMode, mcMode, "multiply_retain_scale", List.of(a, factor),
                    () -> money(cur, a, mc).multiplyRetainScale(new BigDecimal(factor), mc).toString());
            record(cur, tenantMode, mcMode, "round_to_multiples_of", List.of(a, String.valueOf(multiple)),
                    () -> Money.roundToMultiplesOf(money(cur, a, mc), multiple, mc).toString());
            record(cur, tenantMode, mcMode, "negate", List.of(a), () -> money(cur, a, mc).negated().toString());
            record(cur, tenantMode, mcMode, "abs", List.of(a), () -> money(cur, a, mc).abs().toString());
            record(cur, tenantMode, mcMode, "total", List.of(a, b, third),
                    () -> Money.total(money(cur, a, mc), money(cur, b, mc), money(cur, third, mc)).toString());
            // chained: rounding at every step is the property most likely to drift
            record(cur, tenantMode, mcMode, "chain", List.of(a, b, factor, divisor),
                    () -> money(cur, a, mc).plus(money(cur, b, mc)).multipliedBy(new BigDecimal(factor)).dividedBy(new BigDecimal(divisor), mc).toString());
        }
    }

    static Money money(Cur cur, String amount, MathContext mc) {
        return Money.of(cur.data(), new BigDecimal(amount), mc);
    }

    static String pickAmount() {
        return random.nextInt(3) == 0 ? FIXED_AMOUNTS[random.nextInt(FIXED_AMOUNTS.length)] : randomDecimal();
    }

    static String pick(String[] values, int oneIn) {
        return random.nextInt(oneIn) == 0 ? randomFactor() : values[random.nextInt(values.length)];
    }

    // up to 12 integer digits and 0 to 6 decimals, sometimes negative, sometimes a tie at the 2nd or 3rd decimal
    static String randomDecimal() {
        int intDigits = 1 + random.nextInt(12);
        StringBuilder sb = new StringBuilder();
        if (random.nextInt(4) == 0) {
            sb.append('-');
        }
        sb.append(1 + random.nextInt(9));
        for (int i = 1; i < intDigits; i++) {
            sb.append(random.nextInt(10));
        }
        int decimals = random.nextInt(7);
        if (decimals > 0) {
            sb.append('.');
            if (random.nextInt(3) == 0 && decimals >= 3) {
                sb.append(random.nextInt(10)).append(random.nextInt(10)).append('5'); // a tie at the third decimal
            } else {
                for (int i = 0; i < decimals; i++) {
                    sb.append(random.nextInt(10));
                }
            }
        }
        return sb.toString();
    }

    static String randomFactor() {
        StringBuilder sb = new StringBuilder();
        if (random.nextInt(5) == 0) {
            sb.append('-');
        }
        sb.append(random.nextInt(20));
        sb.append('.');
        int decimals = 1 + random.nextInt(24);
        for (int i = 0; i < decimals; i++) {
            sb.append(random.nextInt(10));
        }
        return sb.toString();
    }

    interface Op {
        String run();
    }

    static void record(Cur cur, int tenantMode, int mcMode, String op, List<String> args, Op fn) {
        String result;
        try {
            result = "\"" + fn.run() + "\"";
        } catch (ArithmeticException e) {
            result = "{\"error\":\"arithmetic\"}";
        }
        StringBuilder sb = new StringBuilder();
        sb.append("{\"op\":\"").append(op).append("\",\"currency\":{\"code\":\"").append(cur.code()).append("\",\"places\":").append(cur.places())
                .append(",\"multiples\":").append(cur.multiples() == null ? "null" : cur.multiples()).append("},\"tenant_mode\":").append(tenantMode)
                .append(",\"mc_mode\":").append(mcMode).append(",\"args\":[");
        for (int i = 0; i < args.size(); i++) {
            sb.append(i > 0 ? "," : "").append('"').append(args.get(i)).append('"');
        }
        sb.append("],\"result\":").append(result).append('}');
        out.add(sb.toString());
    }
}
