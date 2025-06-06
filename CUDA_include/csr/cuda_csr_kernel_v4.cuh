#include <cuda_runtime.h>
#include <stdio.h>
#include <cuda.h>
#include <iostream>

#include "../../src/data_structures/csr_matrix.h"

#define WARP_SIZE 32

/******************************************************************************************************************
 * Kernel4: Prodotto matrice-vettore per matrici sparse in formato CSR
 *
 * Ogni warp è responsabile della computazione di una riga della matrice.
 *
 * Uso della Cache L2:
 *   - I dati vengono prima cercati nella Cache L2 prima di accedere alla memoria globale.
 *   - Non garantisce coalescenza nell’accesso, ma riduce la latenza rispetto alla memoria globale.
 *
 * *Uso della riduzione con __shfl_sync*:
 *   - Ogni thread accumula il prodotto scalare per una parte della riga.
 *   - La somma finale viene calcolata collaborativamente tra i thread del warp usando __shfl_sync.
 *
 * *Possibili svantaggi*:
 *   - La dipendenza dalla Cache L2 non garantisce sempre un miglioramento prestazionale.
 *   - L’uso della riduzione con __shfl_sync può introdurre errori numerici nel formato double.
 ******************************************************************************************************************/

#define WARP_SIZE 32

__global__ void csr_matvec_warp_cacheL2(CSR_matrix d_Mat, int M, double *x, double *y)
{
    int row = blockIdx.x * blockDim.y + threadIdx.y;
    int lane = threadIdx.x;

    if (row < M)
    {
        double sum = 0.0;
        int start_row = d_Mat.IRP[row];
        int end_row = d_Mat.IRP[row + 1];

        // Utilizzo di un puntatore per migliorare l'efficienza degli accessi a memoria
        double *AS_ptr = d_Mat.AS + start_row;
        int *JA_ptr = d_Mat.JA + start_row;

        for (int j = lane; j < (end_row - start_row); j += WARP_SIZE)
        {
            double a_val = __ldg(&AS_ptr[j]);
            int col_index = __ldg(&JA_ptr[j]);
            sum += a_val * __ldg(&x[col_index]);
        }

        // Alternativa alla riduzione con __shfl_down_sync, usando operazioni XOR per migliorare parallelismo
        for (int offset = WARP_SIZE / 2; offset > 0; offset /= 2)
        {
            sum += __shfl_sync(0xFFFFFFFF, sum, offset);
        }

        if (lane == 0)
        {
            y[row] = sum;
        }
    }
}

/* L2 non aumenta le prestazione quando:
1. Accesso ai dati non ripetuto spesso

    La Cache L2 è utile se gli stessi dati vengono riutilizzati più volte.
    Se i dati vengono caricati una sola volta e non riutilizzati, la cache non porta vantaggi significativi.

2 Set associativity e evictions

    La Cache L2 ha un numero limitato di blocchi (associatività).
    Se ci sono troppi dati diversi in uso contemporaneamente, alcuni verranno espulsi dalla cache, vanificando il vantaggio.

3 Accesso non coalescente

    Anche se i dati sono in cache, se i thread accedono a indirizzi casuali e non sequenziali, ci sarà overhead.
    L'accesso ideale è quando i thread di un warp leggono dati contigui (coalescenza).

4 Concorrenza con altri processi GPU

    Se ci sono altri kernel o stream sulla GPU, la Cache L2 potrebbe essere condivisa e quindi meno efficace per il kernel attuale.

5 Dipendenza dall'architettura GPU

    Alcune GPU hanno cache L2 più piccole o meno efficienti, quindi il miglioramento può variare tra modelli diversi.
*/