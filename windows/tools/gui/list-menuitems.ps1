Add-Type -AssemblyName UIAutomationClient
$desk = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)
$items = $desk.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
foreach ($i in $items) {
  $r = $i.Current.BoundingRectangle
  if ($r.Width -gt 0) {
    Write-Output ("{0} | X={1:N0} Y={2:N0} W={3:N0} H={4:N0}" -f $i.Current.Name, $r.X, $r.Y, $r.Width, $r.Height)
  }
}
