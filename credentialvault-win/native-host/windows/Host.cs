using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

internal static class CredentialVaultNativeHost
{
    private const string ExtensionOrigin = "chrome-extension://micgojkeebpbmhlbepmiebomdokpbcdk/";
    private const int MaxMessageBytes = 1024 * 1024;

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0 || args[0] != ExtensionOrigin)
                return Reply("{\"ok\":false,\"error\":\"Unauthorized extension origin.\"}");

            byte[] header = ReadExactly(Console.OpenStandardInput(), 4);
            int length = BitConverter.ToInt32(header, 0);
            if (length < 1 || length > MaxMessageBytes)
                return Reply("{\"ok\":false,\"error\":\"Invalid message size.\"}");

            string request = new UTF8Encoding(false, true).GetString(ReadExactly(Console.OpenStandardInput(), length));
            Match match = Regex.Match(request, "\\\"action\\\"\\s*:\\s*\\\"(check|install)\\\"");
            if (!match.Success)
                return Reply("{\"ok\":false,\"error\":\"Unsupported updater action.\"}");

            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CredentialVault");
            string updater = Path.Combine(root, "dependency.ps1");
            if (!File.Exists(updater))
                return Reply("{\"ok\":false,\"error\":\"Updater is not installed. Run the Credential Vault installer again.\"}");

            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = powershell;
            start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(updater) + " -NativeAction " + match.Groups[1].Value;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;

            using (Process process = Process.Start(start))
            {
                StringBuilder stdout = new StringBuilder();
                StringBuilder stderr = new StringBuilder();
                process.OutputDataReceived += (s, e) => { if (e.Data != null) stdout.AppendLine(e.Data); };
                process.ErrorDataReceived += (s, e) => { if (e.Data != null) stderr.AppendLine(e.Data); };
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit(180000))
                {
                    process.Kill();
                    return Reply("{\"ok\":false,\"error\":\"Update check timed out. Try again.\"}");
                }
                process.WaitForExit();
                string response = stdout.ToString().Trim();
                if (response.Length == 0)
                    response = "{\"ok\":false,\"error\":\"Updater failed. Run the installer again or check its log.\"}";
                return Reply(response);
            }
        }
        catch (Exception)
        {
            return Reply("{\"ok\":false,\"error\":\"Native updater failed to start. Run the installer again.\"}");
        }
    }

    private static byte[] ReadExactly(Stream stream, int count)
    {
        byte[] data = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int read = stream.Read(data, offset, count - offset);
            if (read == 0) throw new EndOfStreamException();
            offset += read;
        }
        return data;
    }

    private static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }

    private static int Reply(string json)
    {
        byte[] payload = Encoding.UTF8.GetBytes(json);
        byte[] header = BitConverter.GetBytes(payload.Length);
        Stream output = Console.OpenStandardOutput();
        output.Write(header, 0, header.Length);
        output.Write(payload, 0, payload.Length);
        output.Flush();
        return 0;
    }
}