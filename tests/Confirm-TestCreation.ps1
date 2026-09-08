function Confirm-TestCreation($cache, $number, $url = 'http://localhost:8808', $tenant = 'SOURCE', $destination = 'TARGET') {
  & (Get-Module CrossroadsIntegration) {
    param($cache, $number, $url, $tenant, $destination)
    $order = [pscustomobject]@{ order_number = $number; updated_date = '2026-01-01T00:00:00'; progress = 'assigned' }
    $request = [pscustomobject]@{ kind = 'create'; path = '/v1/order/create'; payload = @{ origin_order_number = $number; note = 'earlier snapshot' } }
    $hash = Get-RequestHash $url $request $tenant $destination
    $item = New-DeliveryItem $order $request $hash 'create' $url $cache $tenant $destination 'X90' 'synced' ([pscustomobject]@{ status = 'synced' })
    Write-DeliveryItem $item.file $item.data
  } $cache $number $url $tenant $destination
}
