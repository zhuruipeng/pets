// 备案「公钥」字段格式自查
// 腾讯云输入框只接受「字母大小写 + 数字 + + - = / ,」，不支持中文。
// 所以 Base64 会被拒（实测报红），必须填十六进制。
// 用法：node check_beian_pubkey.js            （不带参数 = 跑内置自检）
//      node check_beian_pubkey.js <你的公钥>  （校验你粘贴的那串）

const HEX_RE = /^[0-9A-Fa-f]+$/;
const ALLOWED_RE = /^[0-9A-Za-z+\-=/,]+$/;

// 从 keystore 提取的 2048 位 RSA 模数（十六进制，512 字符）
const KEY = 'C7338140AFD58D780DE8AD4CC36D77813C964906CBB52062A072CEB4917E276DBB4A6AE80A0C4C2A86DF8B57D5919E458D108853E0EABFD647CC836ED8DADF007BF852CBA740D8893232887046E8782E11578293CA667AB86B8FB09CD8A200F0103F3286313F3D9EFC16F25E957DE72B49A05BCBB940FC532E950B7298EDE1AE76E4F8EE2BD674563F0F8EF5F3E4109412907D5DF9D2F732C0D60A3EB76086AA24A8E77D711565381F31D98D12F76AB617F342D807E51859B21052E398DB662EB2ACF87222A922879AA273CE8D9B805116DFF232A3FF010FC850126545B7208D66D2E85F74A36963011D4B3F61D2A4876F2B38A5C395BAEB3B88181504EEA063';

function check(label, v) {
  const s = (v || '').trim();
  const problems = [];
  if (!s) problems.push('空值');
  if (/\s/.test(s)) problems.push('含空格/换行（输入框不接受）');
  if (/[^\x20-\x7E]/.test(s)) problems.push('含非 ASCII 字符（如中文）');
  if (/[+\/=]/.test(s) && !HEX_RE.test(s)) problems.push('像 Base64（含 + / = 但不是纯十六进制）—— 腾讯云会拒');
  if (!ALLOWED_RE.test(s)) problems.push('含输入框不允许的字符');
  if (!HEX_RE.test(s)) problems.push('不是纯十六进制');
  if (HEX_RE.test(s) && s.length % 2 !== 0) problems.push('十六进制长度应为偶数');
  if (HEX_RE.test(s) && s.replace(/^0*/, '').length !== 512) {
    problems.push(`有效长度 ${s.replace(/^0*/, '').length}，2048 位 RSA 模数应为 512`);
  }
  const ok = problems.length === 0;
  console.log(`${ok ? '✅' : '❌'} ${label}`);
  console.log(`   长度=${s.length}  有效长度=${s.replace(/^0*/, '').length}`);
  if (!ok) problems.forEach(p => console.log(`   ⚠️  ${p}`));
  return ok;
}

console.log('=== 腾讯云备案「公钥」字段格式校验 ===\n');
const arg = process.argv[2];
if (arg) {
  const ok = check('你粘贴的公钥', arg);
  console.log(ok ? '\n结论：可以提交' : '\n结论：请改正后重填');
  process.exit(ok ? 0 : 1);
}

console.log('未传入参数，跑内置自检：\n');
check('十六进制格式（应该通过）', KEY);
console.log('');
check('Base64 格式（应该被拒）', 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxzOBQK/VjXgN6K1Mw2==');
